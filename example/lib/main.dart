import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_wearables_health_sdk/health_data_type.dart';
import 'package:open_wearables_health_sdk/open_wearables_health_sdk.dart';

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
      title: 'Health Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF2D55), brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF2F2F7),
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.black,
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
          // Large title app bar (Apple style)
          SliverAppBar(
            pinned: true,
            expandedHeight: 100,
            flexibleSpace: FlexibleSpaceBar(
              title: const Text('Health Sync'),
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
            ),
            actions: [
              CupertinoButton(
                padding: const EdgeInsets.all(12),
                child: const Icon(CupertinoIcons.doc_text, size: 24),
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
                  // Status Card
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          // Status indicator ring
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _isSyncing
                    ? [const Color(0xFF34C759), const Color(0xFF30D158)]
                    : [const Color(0xFFFF3B30), const Color(0xFFFF453A)],
              ),
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
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.3),
                ),
                const SizedBox(height: 4),
                Text(
                  _isSignedIn ? 'Connected to ${_hostController.text}' : 'Not connected',
                  style: TextStyle(fontSize: 15, color: Colors.grey[600], letterSpacing: -0.2),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_isLoading) const CupertinoActivityIndicator(),
        ],
      ),
    );
  }

  Widget _buildLoginSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              'CONNECT',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey, letterSpacing: 0.5),
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
              child: CupertinoButton.filled(
                onPressed: _isLoading ? null : _connectWithInvitationCode,
                borderRadius: BorderRadius.circular(12),
                child: _isLoading
                    ? const CupertinoActivityIndicator(color: Colors.white)
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
          Icon(icon, color: Colors.grey[400], size: 24),
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
              style: const TextStyle(fontSize: 17),
              placeholderStyle: TextStyle(fontSize: 17, color: Colors.grey[400]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Divider(height: 1, color: Colors.grey[200]),
    );
  }

  Widget _buildActionsSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        children: [
          if (!_isAuthorized)
            _buildActionTile(
              icon: CupertinoIcons.heart,
              iconColor: const Color(0xFFFF2D55),
              title: 'Authorize Health',
              subtitle: 'Grant access to health data',
              onTap: _requestAuthorization,
            ),
          if (_isAuthorized) ...[
            _buildActionTile(
              icon: _isSyncing ? CupertinoIcons.pause : CupertinoIcons.play,
              iconColor: const Color(0xFF34C759),
              title: _isSyncing ? 'Stop Sync' : 'Start Sync',
              subtitle: _isSyncing ? 'Background sync is active' : 'Begin syncing health data',
              onTap: _isSyncing ? _stopBackgroundSync : _startBackgroundSync,
            ),
            _buildDivider(),
            _buildActionTile(
              icon: CupertinoIcons.arrow_2_circlepath,
              iconColor: const Color(0xFF007AFF),
              title: 'Sync Now',
              subtitle: 'Force an immediate sync',
              onTap: _syncNow,
            ),
          ],
          _buildDivider(),
          _buildActionTile(
            icon: CupertinoIcons.square_arrow_left,
            iconColor: const Color(0xFFFF3B30),
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
                color: iconColor.withValues(alpha: 0.12),
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
                      color: destructive ? const Color(0xFFFF3B30) : Colors.black,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(subtitle, style: TextStyle(fontSize: 14, color: Colors.grey[500], letterSpacing: -0.1)),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: Colors.grey[300], size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusMessage() {
    final isError = _statusMessage.toLowerCase().contains('error') || _statusMessage.toLowerCase().contains('failed');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isError
            ? const Color(0xFFFF3B30).withValues(alpha: 0.1)
            : const Color(0xFF34C759).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isError ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.checkmark_circle,
            color: isError ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 15,
                color: isError ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
                fontWeight: FontWeight.w500,
              ),
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
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F2F7),
        title: const Text(
          'Sync Logs',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.black),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Icon(CupertinoIcons.back, color: Color(0xFF007AFF)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          CupertinoButton(
            padding: const EdgeInsets.all(12),
            child: const Icon(CupertinoIcons.trash, color: Color(0xFFFF3B30)),
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
                        Icon(CupertinoIcons.doc_text, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text('No logs yet', style: TextStyle(fontSize: 17, color: Colors.grey[400])),
                      ],
                    ),
                  );
                }

                if (logs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(CupertinoIcons.search, size: 48, color: Colors.grey[300]),
                        const SizedBox(height: 12),
                        Text('No results', style: TextStyle(fontSize: 17, color: Colors.grey[400])),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: logs.length,
                  // Optimize rendering
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

// Simplified log item widget for better performance
class _LogItem extends StatelessWidget {
  final String log;

  const _LogItem({required this.log});

  @override
  Widget build(BuildContext context) {
    final Color dotColor;
    if (log.contains('❌')) {
      dotColor = const Color(0xFFFF3B30);
    } else if (log.contains('✅')) {
      dotColor = const Color(0xFF34C759);
    } else {
      dotColor = const Color(0xFFE5E5EA);
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(10))),
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
              style: const TextStyle(fontSize: 13, fontFamily: 'Menlo', color: Color(0xFF666666), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
