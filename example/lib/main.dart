import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_wearables_health_sdk/health_data_type.dart';
import 'package:open_wearables_health_sdk/open_wearables_health_sdk.dart';

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

  runApp(const MyApp());
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
      title: 'Open Wearables',
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
    });

    // Handle auth errors (401) - sign out and redirect to login
    MethodChannelOpenWearablesHealthSdk.authErrorStream.listen((error) {
      final statusCode = error['statusCode'];
      final message = error['message'] ?? 'Authentication error';
      _addLog('🔒 Auth error: $statusCode - $message');
      _handleAuthError();
    });
  }

  Future<void> _handleAuthError() async {
    // Sign out and reset state
    try {
      await OpenWearablesHealthSdk.signOut();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _isSignedIn = false;
        _isAuthorized = false;
        _isSyncing = false;
        _statusMessage = 'Session expired - please sign in again';
      });
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _invitationCodeController.dispose();
    super.dispose();
  }

  Future<void> _autoConfigureOnStartup() async {
    setState(() => _isLoading = true);
    try {
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

      if (hasUserId && hasAccessToken && hasHost && wasSyncActive) {
        await OpenWearablesHealthSdk.configure(host: credentials['host'] as String);
        _checkStatus();
        _setStatus('Session restored');
      }
    } catch (e) {
      debugPrint('Auto-configure failed: $e');
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

      _setStatus('Connected successfully');
      _checkStatus();
    } catch (e) {
      _setStatus('Connection failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _checkStatus() {
    setState(() {
      _isSignedIn = OpenWearablesHealthSdk.isSignedIn;
      _isSyncing = OpenWearablesHealthSdk.isSyncActive;
    });
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
      _setStatus('Signed out');
      _checkStatus();
      setState(() {
        _isAuthorized = false;
        _isSyncing = false;
        _invitationCodeController.clear();
      });
    } catch (e) {
      _setStatus('Error: $e');
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
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _startBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      final started = await OpenWearablesHealthSdk.startBackgroundSync();
      setState(() => _isSyncing = started);
      _setStatus(started ? 'Sync started' : 'Could not start sync');
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _stopBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      await OpenWearablesHealthSdk.stopBackgroundSync();
      setState(() => _isSyncing = false);
      _setStatus('Sync stopped');
    } catch (e) {
      _setStatus('Error: $e');
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
    } catch (e) {
      _setStatus('Error: $e');
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
                'Open Wearables',
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
                  const SizedBox(height: 24),

                  if (!_isSignedIn) ...[_buildLoginSection()] else ...[_buildActionsSection()],

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
                  _isSignedIn ? 'Connected to ${_hostController.text}' : 'Not connected',
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
              subtitle: _isSyncing ? 'Background sync is active' : 'Begin syncing health data',
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
