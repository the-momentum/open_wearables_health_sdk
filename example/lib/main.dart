import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_wearables_health_sdk/health_data_type.dart';
import 'package:open_wearables_health_sdk/open_wearables_health_sdk.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Open Wearables design tokens
class OWColors {
  static const background = Color(0xFF09090B); // zinc-950
  static const surface = Color(0xFF18181B); // zinc-900
  static const surfaceLight = Color(0xFF27272A); // zinc-800
  static const border = Color(0xFF27272A); // zinc-800
  static const borderSubtle = Color(0xFF18181B); // zinc-900
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA1A1AA); // zinc-400
  static const textLabel = Color(0xFFD4D4D8); // zinc-300
  static const textMuted = Color(0xFF71717A); // zinc-500
  static const textFooter = Color(0xFF52525B); // zinc-600
  static const accent = Color(0xFFE4E4E7); // zinc-200
  static const accentIndigo = Color(0xFF6366F1); // indigo
  static const success = Color(0xFF4ADE80); // green-400
  static const error = Color(0xFFEF4444); // red-500
  static const buttonBg = Color(0xFFFFFFFF);
  static const buttonText = Color(0xFF000000);
  static const buttonHover = Color(0xFFE4E4E7); // zinc-200
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SentryFlutter.init((options) {
    options.dsn = 'https://3d912364254042549967f3560053f841@sentry.mntm.dev/109';
  }, appRunner: () => runApp(MyApp()));
}

// Simple in-memory logs (limited to 500 entries for performance)
final List<String> appLogs = [];
const int _maxLogEntries = 500;

// Notifier to trigger rebuilds when logs change (with throttling)
final logUpdateNotifier = ValueNotifier<int>(0);
DateTime _lastLogUpdate = DateTime.now();
bool _pendingUpdate = false;

void _addLog(String message) {
  appLogs.add(message);
  if (appLogs.length > _maxLogEntries) {
    appLogs.removeRange(0, appLogs.length - _maxLogEntries);
  }

  // Throttle UI updates to max 5 per second
  final now = DateTime.now();
  if (now.difference(_lastLogUpdate).inMilliseconds > 200) {
    _lastLogUpdate = now;
    logUpdateNotifier.value++;
    _pendingUpdate = false;
  } else if (!_pendingUpdate) {
    _pendingUpdate = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      if (_pendingUpdate) {
        _lastLogUpdate = DateTime.now();
        logUpdateNotifier.value++;
        _pendingUpdate = false;
      }
    });
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vytls',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: OWColors.accent,
          brightness: Brightness.dark,
          surface: OWColors.background,
        ),
        scaffoldBackgroundColor: OWColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: OWColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: OWColors.textPrimary,
            fontSize: 34,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
          ),
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _hostController = TextEditingController();
  final _invitationCodeController = TextEditingController();

  bool _isLoading = false;
  String _statusMessage = '';

  bool _isSignedIn = false;
  bool _isAuthorized = false;
  bool _isSyncing = false;

  // Sync days back selection
  int? _syncDaysBack; // null = full sync
  final _customDaysController = TextEditingController();
  bool _isCustomDays = false;

  // ── Sync progress tracking ────────────────────────────────────────
  // Driven by parsing the native logStream (more robust than polling
  // getSyncStatus, because the SDK clears the state file on completion +
  // userKey mismatches can return nil mid-sync). The log lines we care
  // about all flow through MethodChannelOpenWearablesHealthSdk.logStream
  // and are already subscribed in _subscribeToNativeLogs.
  //
  // Parsed signals:
  //   "Types to sync (N):"           → _totalTypes = N
  //   "<TypeName>: complete (anchor"  → _completedTypes += 1
  //   "Sending X KB, Y items"         → _recordsSent += Y
  //   "Sync complete: X samples ..."  → final freeze
  //   "Sync started"                  → reset counters, start timer
  Timer? _progressTimer;          // only used to nudge UI repaints for ETA
  DateTime? _syncStartedAt;
  int _totalTypes = 0;            // 0 until first log line tells us
  int _completedTypes = 0;
  int _recordsSent = 0;
  bool _syncFinishedFlash = false; // true briefly after final "Sync complete"
  bool _keepScreenAwake = true;

  // Provider selection (Android only)
  List<AvailableProvider> _availableProviders = [];
  String? _selectedProviderId;

  @override
  void initState() {
    super.initState();
    _subscribeToNativeLogs();
    _autoConfigureOnStartup();
  }

  void _subscribeToNativeLogs() {
    MethodChannelOpenWearablesHealthSdk.logStream.listen((message) {
      final timestamp = DateTime.now().toIso8601String().split('T').last.split('.').first;
      _addLog('$timestamp $message');

      // Parse progress signals from the native log stream.
      _parseProgressFromLog(message);

      Sentry.addBreadcrumb(Breadcrumb(category: 'sdk.log', message: message, level: _sentryLevelFromLog(message)));
    });

    // Handle auth errors (401) - sign out and redirect to login
    MethodChannelOpenWearablesHealthSdk.authErrorStream.listen((error) {
      final statusCode = error['statusCode'];
      final message = error['message'] ?? 'Authentication error';
      _addLog('🔒 Auth error: $statusCode - $message');

      Sentry.captureEvent(
        SentryEvent(
          message: SentryMessage('Auth error: forced disconnect'),
          level: SentryLevel.error,
          tags: {'statusCode': '$statusCode'},
          contexts: Contexts()..['auth_error'] = error,
        ),
      );

      _handleAuthError();
    });
  }

  SentryLevel _sentryLevelFromLog(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('error') || lower.contains('failed') || lower.contains('401')) {
      return SentryLevel.error;
    }
    if (lower.contains('warn') || lower.contains('retry') || lower.contains('rejected')) {
      return SentryLevel.warning;
    }
    return SentryLevel.info;
  }

  Future<void> _handleAuthError() async {
    Sentry.addBreadcrumb(
      Breadcrumb(category: 'auth', message: 'Signing out due to auth error', level: SentryLevel.warning),
    );

    try {
      await OpenWearablesHealthSdk.signOut();
    } catch (_) {}

    Sentry.configureScope((scope) => scope.setUser(null));

    if (mounted) {
      setState(() {
        _isSignedIn = false;
        _isAuthorized = false;
        _isSyncing = false;
        _statusMessage = 'Session expired - please sign in again';
      });
      _stopProgressTracking();
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _invitationCodeController.dispose();
    _customDaysController.dispose();
    _progressTimer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  // ── Progress tracking (log-parser driven) ───────────────────────

  void _startProgressTracking() {
    setState(() {
      _syncStartedAt = DateTime.now();
      _totalTypes = 0;
      _completedTypes = 0;
      _recordsSent = 0;
      _syncFinishedFlash = false;
    });
    _progressTimer?.cancel();
    // Tick once a second purely so the elapsed/ETA strings refresh in UI.
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (_keepScreenAwake) {
      WakelockPlus.enable();
    }
  }

  void _stopProgressTracking({bool keepFinalSnapshot = false}) {
    _progressTimer?.cancel();
    _progressTimer = null;
    WakelockPlus.disable();
    if (mounted && !keepFinalSnapshot) {
      setState(() {
        _syncStartedAt = null;
        _totalTypes = 0;
        _completedTypes = 0;
        _recordsSent = 0;
        _syncFinishedFlash = false;
      });
    }
  }

  /// Parses one native log line for progress signals. Cheap regex matches —
  /// runs on every log message so kept very tight.
  void _parseProgressFromLog(String message) {
    if (!_isSyncing && !_syncFinishedFlash) return;

    // "Types to sync (N): TypeA, TypeB, ..."
    final typesMatch = RegExp(r'Types to sync \((\d+)\)').firstMatch(message);
    if (typesMatch != null) {
      final n = int.tryParse(typesMatch.group(1) ?? '');
      if (n != null && mounted) {
        setState(() => _totalTypes = n);
      }
      return;
    }

    // "<TypeName>: complete (anchor captured)" — one type fully done.
    if (message.contains('complete (anchor captured)')) {
      if (mounted) {
        setState(() => _completedTypes += 1);
      }
      return;
    }

    // "Sending X KB, Y items (...)" — chunk being POSTed.
    final sendMatch = RegExp(r'Sending [\d.]+ KB, (\d+) items').firstMatch(message);
    if (sendMatch != null) {
      final n = int.tryParse(sendMatch.group(1) ?? '');
      if (n != null && mounted) {
        setState(() => _recordsSent += n);
      }
      return;
    }

    // "Sync complete: X samples across Y types" — final summary; freeze values.
    final completeMatch = RegExp(r'Sync complete: (\d+) samples across (\d+) types').firstMatch(message);
    if (completeMatch != null) {
      final samples = int.tryParse(completeMatch.group(1) ?? '');
      final types = int.tryParse(completeMatch.group(2) ?? '');
      if (mounted) {
        // Stop the 1s UI tick immediately so elapsed timer freezes at the
        // value it had at completion. Without this it would keep ticking
        // forever (or for 30s) past the actual sync end.
        _progressTimer?.cancel();
        _progressTimer = null;
        WakelockPlus.disable();
        setState(() {
          if (samples != null) _recordsSent = samples;
          if (types != null) _completedTypes = types;
          _syncFinishedFlash = true;
        });
        // Hold final snapshot visible for 30s, then auto-collapse.
        Future.delayed(const Duration(seconds: 30), () {
          if (mounted) {
            setState(() => _syncFinishedFlash = false);
            _stopProgressTracking();
          }
        });
      }
      return;
    }

    // "Sync started" — a new sync session began (e.g., observer-driven incremental).
    if (message.contains('Sync started') && !_isSyncing) {
      // SDK started a sync without explicit user action (background observer).
      // Treat as new session — reset counters but keep tracking enabled.
      if (mounted) {
        setState(() {
          _isSyncing = true;
          _syncStartedAt = DateTime.now();
          _totalTypes = 0;
          _completedTypes = 0;
          _recordsSent = 0;
          _syncFinishedFlash = false;
        });
      }
    }
  }

  Future<void> _autoConfigureOnStartup() async {
    setState(() => _isLoading = true);
    try {
      await OpenWearablesHealthSdk.setLogLevel(OWLogLevel.always);
      final credentials = await OpenWearablesHealthSdk.getStoredCredentials();
      final hasUserId = credentials['userId'] != null && (credentials['userId'] as String).isNotEmpty;
      final hasAccessToken =
          (credentials['accessToken'] != null && (credentials['accessToken'] as String).isNotEmpty) ||
          (credentials['apiKey'] != null && (credentials['apiKey'] as String).isNotEmpty);
      final hasHost = credentials['host'] != null && (credentials['host'] as String).isNotEmpty;
      final wasSyncActive = credentials['isSyncActive'] == true;

      if (hasHost) {
        setState(() {
          _hostController.text = credentials['host'] as String;
        });
      }

      // Restore selected provider if stored
      final storedProvider = credentials['provider'] as String?;
      if (storedProvider != null) {
        setState(() => _selectedProviderId = storedProvider);
      }

      if (hasUserId && hasAccessToken && hasHost && wasSyncActive) {
        await OpenWearablesHealthSdk.configure(host: credentials['host'] as String);
        _checkStatus();
        _setStatus('Session restored');
      }

      if (Platform.isAndroid) {
        await _loadAvailableProviders();
        await OpenWearablesHealthSdk.setSyncNotification(
          title: '🏃 Vytls',
          text: '⚡ Sync in progress — keeping your health data fresh 💪',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Auto-configure failed: $e');
      Sentry.captureException(e, stackTrace: stackTrace, hint: Hint.withMap({'operation': 'autoConfigureOnStartup'}));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadAvailableProviders() async {
    try {
      final providers = await OpenWearablesHealthSdk.getAvailableProviders();
      setState(() {
        _availableProviders = providers;
        if (_selectedProviderId == null && providers.isNotEmpty) {
          _selectedProviderId = providers.first.id;
        }
      });
    } catch (e) {
      debugPrint('Failed to load providers: $e');
    }
  }

  Future<void> _selectProvider(String providerId) async {
    final provider = AndroidHealthProvider.fromId(providerId);
    if (provider == null) return;

    setState(() => _isLoading = true);
    try {
      await OpenWearablesHealthSdk.setProvider(provider);
      setState(() {
        _selectedProviderId = providerId;
        _isAuthorized = false;
      });
      _setStatus('Provider set to ${provider.displayName}');
    } catch (e, stackTrace) {
      _setStatus('Failed to set provider: $e');
      Sentry.captureException(
        e,
        stackTrace: stackTrace,
        hint: Hint.withMap({'operation': 'selectProvider', 'providerId': providerId}),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _connectWithInvitationCode() async {
    final host = _hostController.text.trim();
    final invitationCode = _invitationCodeController.text.trim();

    if (host.isEmpty || invitationCode.isEmpty) {
      _setStatus('Please fill Host and Invitation Code');
      return;
    }

    setState(() => _isLoading = true);

    try {
      _setStatus('Redeeming invitation code...');

      // Build redeem URL: {host}/api/v1/invitation-code/redeem
      final h = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
      final redeemUrl = Uri.parse('$h/api/v1/invitation-code/redeem');

      final response = await http.post(
        redeemUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': invitationCode}),
      );

      if (response.statusCode != 200) {
        _setStatus('Redeem failed (${response.statusCode}): ${response.body}');
        Sentry.captureEvent(
          SentryEvent(
            message: SentryMessage('Invitation code redeem failed'),
            level: SentryLevel.warning,
            tags: {'statusCode': '${response.statusCode}', 'host': host},
            contexts: Contexts()
              ..['response_details'] = {
                'body': response.body.length > 500 ? response.body.substring(0, 500) : response.body,
              },
          ),
        );
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = data['access_token'] as String?;
      final refreshToken = data['refresh_token'] as String?;
      final userId = data['user_id'] as String?;

      if (accessToken == null || refreshToken == null || userId == null) {
        _setStatus('Invalid response from server');
        return;
      }

      // Configure SDK with host
      await OpenWearablesHealthSdk.configure(host: host);
      _checkStatus();

      // Sign in with the received credentials
      _setStatus('Signing in...');
      final bearerToken = accessToken.startsWith('Bearer ') ? accessToken : 'Bearer $accessToken';
      await OpenWearablesHealthSdk.signIn(userId: userId, accessToken: bearerToken, refreshToken: refreshToken);

      Sentry.configureScope((scope) => scope.setUser(SentryUser(id: userId)));
      _setStatus('Connected successfully');
      _checkStatus();

      if (Platform.isAndroid) {
        await _loadAvailableProviders();
      }
    } catch (e, stackTrace) {
      _setStatus('Connection failed: $e');
      Sentry.captureException(
        e,
        stackTrace: stackTrace,
        hint: Hint.withMap({'operation': 'connectWithInvitationCode'}),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _providerDisplayName(String id) {
    final match = _availableProviders.where((p) => p.id == id);
    if (match.isNotEmpty) return match.first.displayName;
    return AndroidHealthProvider.fromId(id)?.displayName ?? id;
  }

  void _checkStatus() {
    final wasSyncing = _isSyncing;
    setState(() {
      _isSignedIn = OpenWearablesHealthSdk.isSignedIn;
      _isSyncing = OpenWearablesHealthSdk.isSyncActive;
      if (_isSyncing) _isAuthorized = true;
    });
    // If we just discovered a sync is in flight (e.g. app reopened mid-sync),
    // start the progress tracker so the UI catches up.
    if (_isSyncing && !wasSyncing && _progressTimer == null) {
      _startProgressTracking();
    }
  }

  void _setStatus(String message) {
    setState(() => _statusMessage = message);
    final log = '${DateTime.now().toIso8601String().split('T').last.split('.').first} $message';
    _addLog(log);
    debugPrint('[Demo] $message');
  }

  Future<void> _signOut() async {
    setState(() => _isLoading = true);
    try {
      await OpenWearablesHealthSdk.signOut();
      Sentry.configureScope((scope) => scope.setUser(null));
      _setStatus('Signed out');
      _checkStatus();
      setState(() {
        _isAuthorized = false;
        _isSyncing = false;
        _invitationCodeController.clear();
      });
    } catch (e, stackTrace) {
      _setStatus('Error: $e');
      Sentry.captureException(e, stackTrace: stackTrace, hint: Hint.withMap({'operation': 'signOut'}));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _requestAuthorization() async {
    setState(() => _isLoading = true);
    try {
      final authorized = await OpenWearablesHealthSdk.requestAuthorization(types: HealthDataType.values);
      setState(() => _isAuthorized = authorized);
      _setStatus(authorized ? 'Authorized' : 'Authorization denied');
      if (!authorized) {
        Sentry.captureEvent(
          SentryEvent(message: SentryMessage('Health authorization denied by user'), level: SentryLevel.warning),
        );
      }
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e, stackTrace) {
      _setStatus('Error: $e');
      Sentry.captureException(e, stackTrace: stackTrace, hint: Hint.withMap({'operation': 'requestAuthorization'}));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _startBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      final label = _syncDaysBack != null ? 'last $_syncDaysBack days' : 'full history';
      final started = await OpenWearablesHealthSdk.startBackgroundSync(syncDaysBack: _syncDaysBack);
      setState(() => _isSyncing = started);
      if (started) {
        _startProgressTracking();
      }
      _setStatus(started ? 'Sync started ($label)' : 'Could not start sync');
      if (!started) {
        Sentry.captureEvent(
          SentryEvent(
            message: SentryMessage('Background sync failed to start'),
            level: SentryLevel.warning,
            tags: {'syncDaysBack': '${_syncDaysBack ?? "full"}'},
          ),
        );
      }
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e, stackTrace) {
      _setStatus('Error: $e');
      Sentry.captureException(e, stackTrace: stackTrace, hint: Hint.withMap({'operation': 'startBackgroundSync'}));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _stopBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      await OpenWearablesHealthSdk.stopBackgroundSync();
      setState(() => _isSyncing = false);
      _stopProgressTracking();
      _setStatus('Sync stopped');
    } catch (e, stackTrace) {
      _setStatus('Error: $e');
      Sentry.captureException(e, stackTrace: stackTrace, hint: Hint.withMap({'operation': 'stopBackgroundSync'}));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _isLoading = true);
    try {
      await OpenWearablesHealthSdk.syncNow();
      _setStatus('Sync triggered');
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e, stackTrace) {
      _setStatus('Error: $e');
      Sentry.captureException(e, stackTrace: stackTrace, hint: Hint.withMap({'operation': 'syncNow'}));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 100,
            backgroundColor: OWColors.background,
            flexibleSpace: FlexibleSpaceBar(
              title: const Text(
                'Vytls',
                style: TextStyle(color: OWColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
              ),
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
            ),
            actions: [
              CupertinoButton(
                padding: const EdgeInsets.all(12),
                child: const Icon(CupertinoIcons.doc_text, size: 24, color: OWColors.textSecondary),
                onPressed: () => Navigator.of(context).push(CupertinoPageRoute(builder: (c) => const LogsPage())),
              ),
            ],
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusCard(),
                  // Live progress card — renders while syncing AND for ~30s
                  // after completion so the user sees the final tally.
                  if (_isSyncing || _syncFinishedFlash) ...[
                    const SizedBox(height: 16),
                    _buildProgressCard(),
                  ],
                  const SizedBox(height: 24),

                  if (!_isSignedIn) ...[
                    _buildLoginSection(),
                  ] else ...[
                    if (Platform.isAndroid && _availableProviders.isNotEmpty) ...[
                      _buildProviderSection(),
                      const SizedBox(height: 16),
                    ],
                    if (_isAuthorized && !_isSyncing) ...[_buildSyncRangeSection()],
                    _buildActionsSection(),
                  ],

                  if (_statusMessage.isNotEmpty) ...[const SizedBox(height: 24), _buildStatusMessage()],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: OWColors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OWColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _isSyncing
                    ? [OWColors.success, OWColors.success.withValues(alpha: 0.7)]
                    : [OWColors.error, OWColors.error.withValues(alpha: 0.7)],
              ),
              boxShadow: [
                BoxShadow(
                  color: (_isSyncing ? OWColors.success : OWColors.error).withValues(alpha: 0.3),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              _isSyncing ? CupertinoIcons.checkmark_alt : CupertinoIcons.xmark,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isSyncing ? 'Syncing Active' : 'Not Syncing',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    color: OWColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isSignedIn
                      ? 'Connected${_selectedProviderId != null ? ' via ${_providerDisplayName(_selectedProviderId!)}' : ''}'
                      : 'Not connected',
                  style: const TextStyle(fontSize: 15, color: OWColors.textSecondary, letterSpacing: -0.2),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_isLoading) const CupertinoActivityIndicator(color: OWColors.accent),
        ],
      ),
    );
  }

  // ── Progress card ─────────────────────────────────────────────────
  // Live progress driven by parsing the native log stream. Robust to the
  // SDK clearing its state file mid-flight + handles the streaming sync's
  // multiple session boundaries (start → complete → re-start observer).
  // Shows: completed-types bar, records-sent counter, elapsed timer,
  // rough ETA, wakelock toggle.
  Widget _buildProgressCard() {
    final completedTypes = _completedTypes;
    final sentCount = _recordsSent;
    final totalTypes = _totalTypes > 0 ? _totalTypes : HealthDataType.values.length;
    final progress = _syncFinishedFlash
        ? 1.0
        : (totalTypes > 0 ? (completedTypes / totalTypes).clamp(0.0, 1.0) : 0.0);
    final percent = (progress * 100).toInt();

    String? elapsedStr;
    String? etaStr;
    if (_syncStartedAt != null) {
      final elapsed = DateTime.now().difference(_syncStartedAt!);
      if (elapsed.inHours > 0) {
        elapsedStr = '${elapsed.inHours}h ${elapsed.inMinutes % 60}m';
      } else if (elapsed.inMinutes > 0) {
        elapsedStr = '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
      } else {
        elapsedStr = '${elapsed.inSeconds}s';
      }
      if (elapsed.inSeconds > 5 && completedTypes > 0 && completedTypes < totalTypes) {
        final ratePerSec = completedTypes / elapsed.inSeconds;
        if (ratePerSec > 0) {
          final remainSec = (totalTypes - completedTypes) / ratePerSec;
          if (remainSec < 60) {
            etaStr = '~${remainSec.toInt()}s left';
          } else if (remainSec < 3600) {
            etaStr = '~${(remainSec / 60).toInt()} min left';
          } else {
            etaStr = '~${(remainSec / 3600).toStringAsFixed(1)}h left';
          }
        }
      }
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: OWColors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OWColors.success.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _syncFinishedFlash ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.arrow_down_circle_fill,
                color: OWColors.success,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                _syncFinishedFlash ? 'Sync complete' : 'Sync progress',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: OWColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                _syncFinishedFlash ? '✓' : '$percent%',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: OWColors.success,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: OWColors.surfaceLight,
              valueColor: const AlwaysStoppedAnimation(OWColors.success),
            ),
          ),
          const SizedBox(height: 14),
          _statRow('Types complete', '$completedTypes / $totalTypes'),
          _statRow('Records sent', _formatCount(sentCount)),
          if (elapsedStr != null) _statRow('Elapsed', elapsedStr),
          if (etaStr != null) _statRow('Remaining', etaStr),
          const SizedBox(height: 12),
          const Divider(height: 1, color: OWColors.borderSubtle),
          const SizedBox(height: 8),
          Row(
            children: [
              CupertinoSwitch(
                value: _keepScreenAwake,
                activeTrackColor: OWColors.success,
                onChanged: (v) {
                  setState(() => _keepScreenAwake = v);
                  if (_isSyncing) {
                    if (v) {
                      WakelockPlus.enable();
                    } else {
                      WakelockPlus.disable();
                    }
                  }
                },
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Keep screen awake while syncing',
                  style: TextStyle(fontSize: 14, color: OWColors.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: OWColors.textSecondary)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: OWColors.textPrimary,
              fontWeight: FontWeight.w500,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _formatCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }

  Widget _buildLoginSection() {
    return Container(
      decoration: BoxDecoration(
        color: OWColors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OWColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              'CONNECT',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: OWColors.textMuted,
                letterSpacing: 0.5,
              ),
            ),
          ),
          _buildTextField(
            controller: _hostController,
            placeholder: 'Host (e.g. https://api.example.com)',
            icon: CupertinoIcons.globe,
            keyboardType: TextInputType.url,
          ),
          _buildDivider(),
          _buildTextField(
            controller: _invitationCodeController,
            placeholder: 'Invitation Code',
            icon: CupertinoIcons.ticket,
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _connectWithInvitationCode,
                style: ElevatedButton.styleFrom(
                  backgroundColor: OWColors.buttonBg,
                  foregroundColor: OWColors.buttonText,
                  disabledBackgroundColor: OWColors.buttonHover,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: OWColors.buttonText),
                      )
                    : const Text('Connect', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String placeholder,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: OWColors.textMuted, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              placeholder: placeholder,
              obscureText: obscureText,
              keyboardType: keyboardType,
              autocorrect: false,
              padding: EdgeInsets.zero,
              decoration: const BoxDecoration(),
              style: const TextStyle(fontSize: 17, color: OWColors.textPrimary),
              placeholderStyle: const TextStyle(fontSize: 17, color: OWColors.textMuted),
              cursorColor: OWColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Divider(height: 1, color: OWColors.border.withValues(alpha: 0.5)),
    );
  }

  Widget _buildProviderSection() {
    return Container(
      decoration: BoxDecoration(
        color: OWColors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OWColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text(
              'HEALTH PROVIDER',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: OWColors.textMuted,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Select where to read health data from',
              style: TextStyle(fontSize: 14, color: OWColors.textFooter),
            ),
          ),
          for (int i = 0; i < _availableProviders.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 64),
                child: Divider(height: 1, color: OWColors.border.withValues(alpha: 0.5)),
              ),
            _buildProviderOption(_availableProviders[i]),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildProviderOption(AvailableProvider provider) {
    final isSelected = _selectedProviderId == provider.id;
    final iconData = provider.id == 'samsung' ? CupertinoIcons.device_phone_portrait : CupertinoIcons.heart_circle;

    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: _isLoading
          ? null
          : () {
              if (!isSelected) _selectProvider(provider.id);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (isSelected ? OWColors.accentIndigo : OWColors.textMuted).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(iconData, color: isSelected ? OWColors.accentIndigo : OWColors.textMuted, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    provider.displayName,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: isSelected ? OWColors.textPrimary : OWColors.textSecondary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(
                    provider.id == 'samsung' ? 'Samsung devices with Samsung Health' : 'Universal Android health hub',
                    style: const TextStyle(fontSize: 14, color: OWColors.textMuted, letterSpacing: -0.1),
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? OWColors.accentIndigo : Colors.transparent,
                border: Border.all(color: isSelected ? OWColors.accentIndigo : OWColors.textFooter, width: 2),
              ),
              child: isSelected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncRangeSection() {
    final presets = <({String label, int? days})>[
      (label: 'Full Sync', days: null),
      (label: '1 Day', days: 1),
      (label: '30 Days', days: 30),
      (label: '90 Days', days: 90),
      (label: '365 Days', days: 365),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: OWColors.surface.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: OWColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text(
                'SYNC RANGE',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: OWColors.textMuted,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'How far back to sync health data',
                style: TextStyle(fontSize: 14, color: OWColors.textFooter),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in presets)
                    _buildRangeChip(
                      label: preset.label,
                      isSelected: !_isCustomDays && _syncDaysBack == preset.days,
                      onTap: () => setState(() {
                        _syncDaysBack = preset.days;
                        _isCustomDays = false;
                      }),
                    ),
                  _buildRangeChip(
                    label: 'Custom',
                    isSelected: _isCustomDays,
                    onTap: () => setState(() {
                      _isCustomDays = true;
                      if (_customDaysController.text.isNotEmpty) {
                        _syncDaysBack = int.tryParse(_customDaysController.text);
                      }
                    }),
                  ),
                ],
              ),
            ),
            if (_isCustomDays)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.number, color: OWColors.textMuted, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CupertinoTextField(
                        controller: _customDaysController,
                        placeholder: 'Number of days',
                        keyboardType: TextInputType.number,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: const BoxDecoration(),
                        style: const TextStyle(fontSize: 17, color: OWColors.textPrimary),
                        placeholderStyle: const TextStyle(fontSize: 17, color: OWColors.textMuted),
                        cursorColor: OWColors.accent,
                        onChanged: (value) {
                          setState(() {
                            _syncDaysBack = int.tryParse(value);
                          });
                        },
                      ),
                    ),
                    if (_syncDaysBack != null && _isCustomDays)
                      Text('days', style: const TextStyle(fontSize: 15, color: OWColors.textSecondary)),
                  ],
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildRangeChip({required String label, required bool isSelected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? OWColors.accentIndigo : OWColors.surfaceLight,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? OWColors.accentIndigo : OWColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            color: isSelected ? Colors.white : OWColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildActionsSection() {
    return Container(
      decoration: BoxDecoration(
        color: OWColors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OWColors.border),
      ),
      child: Column(
        children: [
          if (!_isAuthorized)
            _buildActionTile(
              icon: CupertinoIcons.heart,
              iconColor: OWColors.accent,
              title: 'Authorize Health',
              subtitle: 'Grant access to health data',
              onTap: _requestAuthorization,
            ),
          if (_isAuthorized) ...[
            _buildActionTile(
              icon: _isSyncing ? CupertinoIcons.pause : CupertinoIcons.play,
              iconColor: OWColors.success,
              title: _isSyncing ? 'Stop Sync' : 'Start Sync',
              subtitle: _isSyncing
                  ? 'Background sync is active'
                  : 'Sync ${_syncDaysBack != null ? 'last $_syncDaysBack days' : 'full history'}',
              onTap: _isSyncing ? _stopBackgroundSync : _startBackgroundSync,
            ),
            _buildDivider(),
            _buildActionTile(
              icon: CupertinoIcons.arrow_2_circlepath,
              iconColor: OWColors.accentIndigo,
              title: 'Sync Now',
              subtitle: 'Force an immediate sync',
              onTap: _syncNow,
            ),
          ],
          _buildDivider(),
          _buildActionTile(
            icon: CupertinoIcons.square_arrow_left,
            iconColor: OWColors.error,
            title: 'Disconnect',
            subtitle: 'Sign out and stop syncing',
            onTap: _signOut,
            destructive: true,
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: _isLoading ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: destructive ? OWColors.error : OWColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(subtitle, style: const TextStyle(fontSize: 14, color: OWColors.textMuted, letterSpacing: -0.1)),
                ],
              ),
            ),
            const Icon(CupertinoIcons.chevron_right, color: OWColors.textFooter, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusMessage() {
    final isError = _statusMessage.toLowerCase().contains('error') || _statusMessage.toLowerCase().contains('failed');
    final statusColor = isError ? OWColors.error : OWColors.success;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(
            isError ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.checkmark_circle,
            color: statusColor,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(fontSize: 15, color: statusColor, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _searchQuery = '';
  List<String> _cachedFilteredLogs = [];
  int _lastLogCount = 0;
  String _lastSearchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<String> _getFilteredLogs() {
    // Cache filtered logs to avoid recomputing on every build
    if (_lastLogCount == appLogs.length && _lastSearchQuery == _searchQuery) {
      return _cachedFilteredLogs;
    }

    _lastLogCount = appLogs.length;
    _lastSearchQuery = _searchQuery;

    if (_searchQuery.isEmpty) {
      _cachedFilteredLogs = appLogs.reversed.toList();
    } else {
      final query = _searchQuery.toLowerCase();
      _cachedFilteredLogs = appLogs.reversed.where((log) => log.toLowerCase().contains(query)).toList();
    }
    return _cachedFilteredLogs;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OWColors.background,
      appBar: AppBar(
        backgroundColor: OWColors.background,
        title: const Text(
          'Sync Logs',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: OWColors.textPrimary),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Icon(CupertinoIcons.back, color: OWColors.accent),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          CupertinoButton(
            padding: const EdgeInsets.all(12),
            child: const Icon(CupertinoIcons.trash, color: OWColors.error),
            onPressed: () {
              appLogs.clear();
              _cachedFilteredLogs = [];
              _lastLogCount = 0;
              logUpdateNotifier.value++;
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: CupertinoSearchTextField(
              controller: _searchController,
              placeholder: 'Search in logs...',
              onChanged: (value) => setState(() => _searchQuery = value),
              style: const TextStyle(color: OWColors.textPrimary),
              backgroundColor: OWColors.surface,
              placeholderStyle: const TextStyle(color: OWColors.textMuted),
              prefixIcon: const Icon(CupertinoIcons.search, color: OWColors.textMuted),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: logUpdateNotifier,
              builder: (context, _, __) {
                final logs = _getFilteredLogs();

                if (appLogs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(CupertinoIcons.doc_text, size: 48, color: OWColors.textFooter),
                        const SizedBox(height: 12),
                        const Text('No logs yet', style: TextStyle(fontSize: 17, color: OWColors.textMuted)),
                      ],
                    ),
                  );
                }

                if (logs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(CupertinoIcons.search, size: 48, color: OWColors.textFooter),
                        const SizedBox(height: 12),
                        const Text('No results', style: TextStyle(fontSize: 17, color: OWColors.textMuted)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: logs.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _LogItem(log: logs[index]),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LogItem extends StatelessWidget {
  final String log;

  const _LogItem({required this.log});

  @override
  Widget build(BuildContext context) {
    final Color dotColor;
    if (log.contains('❌')) {
      dotColor = OWColors.error;
    } else if (log.contains('✅')) {
      dotColor = OWColors.success;
    } else {
      dotColor = OWColors.textFooter;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OWColors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: OWColors.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              log,
              style: const TextStyle(fontSize: 13, fontFamily: 'Menlo', color: OWColors.textSecondary, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
