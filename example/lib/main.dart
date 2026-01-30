import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:open_wearables_health_sdk/health_data_type.dart';
import 'package:open_wearables_health_sdk/open_wearables_health_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize sync statistics stream
  initSyncStatisticsStream();

  runApp(const MyApp());
}

// Simple in-memory logs (limited to 500 entries for performance)
final List<String> appLogs = [];
const int _maxLogEntries = 500;

// Notifier to trigger rebuilds when logs change (with throttling)
final logUpdateNotifier = ValueNotifier<int>(0);
DateTime _lastLogUpdate = DateTime.now();
bool _pendingUpdate = false;

// Global sync statistics state
final Map<String, int> syncStatistics = <String, int>{};
int totalSyncedCount = 0;
DateTime? lastSyncTimestamp;
final syncStatsNotifier = ValueNotifier<int>(0);
StreamSubscription<Map<String, dynamic>>? _globalSyncStatsSubscription;

// Initialize sync statistics stream subscription
void initSyncStatisticsStream() {
  _globalSyncStatsSubscription?.cancel();
  _globalSyncStatsSubscription = OpenWearablesHealthSdk.syncStatsStream.listen((event) {
    final type = event['type'] as String? ?? '';
    final count = event['count'] as int? ?? 0;
    final timestamp = event['timestamp'] as String?;

    if (type.isNotEmpty && count > 0) {
      syncStatistics[type] = (syncStatistics[type] ?? 0) + count;
      totalSyncedCount += count;
      if (timestamp != null) {
        try {
          lastSyncTimestamp = DateTime.parse(timestamp);
        } catch (e) {
          // Ignore parse errors
        }
      }
      syncStatsNotifier.value++;
    }
  });
}

// Cleanup sync statistics stream subscription
void disposeSyncStatisticsStream() {
  _globalSyncStatsSubscription?.cancel();
  _globalSyncStatsSubscription = null;
}

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
  final _customUrlController = TextEditingController(text: 'https://api.openwearables.io/api/v1/');
  final _userIdController = TextEditingController();
  final _tokenController = TextEditingController();

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
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _tokenController.dispose();
    _customUrlController.dispose();
    super.dispose();
  }

  Future<void> _autoConfigureOnStartup() async {
    setState(() => _isLoading = true);
    try {
      final credentials = await OpenWearablesHealthSdk.getStoredCredentials();
      final hasUserId = credentials['userId'] != null && (credentials['userId'] as String).isNotEmpty;
      final hasAccessToken = credentials['accessToken'] != null && (credentials['accessToken'] as String).isNotEmpty;
      final wasSyncActive = credentials['isSyncActive'] == true;

      setState(() {
        if (credentials['userId'] != null) {
          _userIdController.text = credentials['userId'] as String;
        }
        if (credentials['accessToken'] != null) {
          _tokenController.text = credentials['accessToken'] as String;
        }
      });

      if (hasUserId && hasAccessToken && wasSyncActive) {
        final storedCustomUrl = credentials['customSyncUrl'] as String?;
        await OpenWearablesHealthSdk.configure(
          environment: OpenWearablesHealthSdkEnvironment.production,
          customSyncUrl: storedCustomUrl,
        );
        _checkStatus();
        _setStatus('Session restored');
      }
    } catch (e) {
      debugPrint('Auto-configure failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loginWithToken() async {
    final userId = _userIdController.text.trim();
    final token = _tokenController.text.trim();
    final customUrl = _customUrlController.text.trim();

    if (userId.isEmpty || token.isEmpty) {
      _setStatus('Please fill User ID and Token');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // If URL contains {user_id} placeholder, use it directly; otherwise treat as base URL ending with /api/v1/
      final String fullSyncUrl;
      if (customUrl.contains('{user_id}')) {
        fullSyncUrl = customUrl;
      } else {
        final baseUrl = customUrl.isNotEmpty ? customUrl : 'https://api.openwearables.io/api/v1/';
        // Remove trailing slash if present, then append path
        final normalizedBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
        fullSyncUrl = '$normalizedBase/sdk/users/{user_id}/sync/apple';
      }
      await OpenWearablesHealthSdk.configure(
        environment: OpenWearablesHealthSdkEnvironment.production,
        customSyncUrl: fullSyncUrl,
      );
      _checkStatus();

      _setStatus('Signing in...');
      final authToken = token.startsWith('Bearer ') ? token : 'Bearer $token';
      await OpenWearablesHealthSdk.signIn(userId: userId, accessToken: authToken);

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
        _tokenController.clear();
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
                  _isSignedIn
                      ? 'Connected as ${_userIdController.text.length > 8 ? '${_userIdController.text.substring(0, 8)}...' : _userIdController.text}'
                      : 'Not connected',
                  style: TextStyle(fontSize: 15, color: Colors.grey[600], letterSpacing: -0.2),
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
          _buildTextField(controller: _userIdController, placeholder: 'User ID', icon: CupertinoIcons.person),
          _buildDivider(),
          _buildTextField(
            controller: _tokenController,
            placeholder: 'Token',
            icon: CupertinoIcons.lock,
            obscureText: true,
          ),
          _buildDivider(),
          _buildTextField(controller: _customUrlController, placeholder: 'API URL', icon: CupertinoIcons.link),
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: _isLoading ? null : _loginWithToken,
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
            _buildDivider(),
            _buildActionTile(
              icon: CupertinoIcons.chart_bar,
              iconColor: const Color(0xFF5856D6),
              title: 'Sync Status',
              subtitle: 'View sync progress per data type',
              onTap: () => Navigator.of(context).push(CupertinoPageRoute(builder: (c) => const SyncStatusPage())),
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

// Sync Status Page - displays per-type sync statistics
class SyncStatusPage extends StatefulWidget {
  const SyncStatusPage({super.key});

  @override
  State<SyncStatusPage> createState() => _SyncStatusPageState();
}

class _SyncStatusPageState extends State<SyncStatusPage> {
  // Current session info
  Map<String, dynamic> _sessionStatus = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSessionStatus();
  }

  Future<void> _loadSessionStatus() async {
    setState(() => _isLoading = true);
    try {
      final session = await OpenWearablesHealthSdk.getSyncStatus();
      setState(() {
        _sessionStatus = session;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Failed to load session status: $e');
      setState(() => _isLoading = false);
    }
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  String _formatTimestamp(String? timestamp) {
    if (timestamp == null) return 'Never';
    try {
      final date = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(date);

      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return timestamp;
    }
  }

  IconData _getIconForType(String typeName) {
    final lower = typeName.toLowerCase();
    if (lower.contains('heart') || lower.contains('vo2')) return CupertinoIcons.heart_fill;
    if (lower.contains('step')) return CupertinoIcons.flame_fill;
    if (lower.contains('workout')) return CupertinoIcons.sportscourt_fill;
    if (lower.contains('sleep')) return CupertinoIcons.moon_fill;
    if (lower.contains('distance') || lower.contains('walking') || lower.contains('running'))
      return CupertinoIcons.arrow_right_circle_fill;
    if (lower.contains('energy') || lower.contains('calorie')) return CupertinoIcons.bolt_fill;
    if (lower.contains('blood') || lower.contains('glucose')) return CupertinoIcons.drop_fill;
    if (lower.contains('oxygen') || lower.contains('respiratory')) return CupertinoIcons.wind;
    if (lower.contains('body') ||
        lower.contains('mass') ||
        lower.contains('weight') ||
        lower.contains('height') ||
        lower.contains('bmi'))
      return CupertinoIcons.person_fill;
    if (lower.contains('mindful')) return CupertinoIcons.sparkles;
    if (lower.contains('dietary') ||
        lower.contains('water') ||
        lower.contains('protein') ||
        lower.contains('carb') ||
        lower.contains('fat'))
      return CupertinoIcons.leaf_arrow_circlepath;
    return CupertinoIcons.chart_bar_fill;
  }

  Color _getColorForType(String typeName) {
    final lower = typeName.toLowerCase();
    if (lower.contains('heart') || lower.contains('vo2')) return const Color(0xFFFF2D55);
    if (lower.contains('step') || lower.contains('flight')) return const Color(0xFFFF9500);
    if (lower.contains('workout')) return const Color(0xFF34C759);
    if (lower.contains('sleep')) return const Color(0xFF5856D6);
    if (lower.contains('distance') || lower.contains('walking') || lower.contains('running'))
      return const Color(0xFF007AFF);
    if (lower.contains('energy') || lower.contains('calorie')) return const Color(0xFFFFCC00);
    if (lower.contains('blood') || lower.contains('glucose')) return const Color(0xFFFF3B30);
    if (lower.contains('oxygen') || lower.contains('respiratory')) return const Color(0xFF64D2FF);
    if (lower.contains('body') ||
        lower.contains('mass') ||
        lower.contains('weight') ||
        lower.contains('height') ||
        lower.contains('bmi'))
      return const Color(0xFFAF52DE);
    if (lower.contains('mindful')) return const Color(0xFF30D158);
    if (lower.contains('dietary') ||
        lower.contains('water') ||
        lower.contains('protein') ||
        lower.contains('carb') ||
        lower.contains('fat'))
      return const Color(0xFF32ADE6);
    return const Color(0xFF8E8E93);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F2F7),
        title: const Text(
          'Sync Status',
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
            child: const Icon(CupertinoIcons.refresh, color: Color(0xFF007AFF)),
            onPressed: _loadSessionStatus,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CupertinoActivityIndicator())
          : ValueListenableBuilder<int>(
              valueListenable: syncStatsNotifier,
              builder: (context, _, __) {
                return RefreshIndicator(
                  onRefresh: _loadSessionStatus,
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Summary Card
                              Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFF5856D6), Color(0xFF007AFF)],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF5856D6).withValues(alpha: 0.3),
                                      blurRadius: 20,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: const Icon(
                                            CupertinoIcons.chart_bar_fill,
                                            color: Colors.white,
                                            size: 24,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        const Expanded(
                                          child: Text(
                                            'Total Synced',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _formatNumber(totalSyncedCount),
                                      style: const TextStyle(
                                        fontSize: 48,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        letterSpacing: -1,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'records • Last sync: ${_formatTimestamp(lastSyncTimestamp?.toIso8601String())}',
                                      style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.8)),
                                    ),
                                    if ((_sessionStatus['hasResumableSession'] as bool? ?? false)) ...[
                                      const SizedBox(height: 12),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              CupertinoIcons.arrow_2_circlepath,
                                              color: Colors.white,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Sync in progress: ${_sessionStatus['sentCount'] ?? 0} sent',
                                              style: const TextStyle(fontSize: 13, color: Colors.white),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              const SizedBox(height: 24),

                              // Section header
                              const Padding(
                                padding: EdgeInsets.only(left: 4, bottom: 8),
                                child: Text(
                                  'BY DATA TYPE',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Data types list
                      if (syncStatistics.isEmpty)
                        SliverToBoxAdapter(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16),
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                            child: Column(
                              children: [
                                Icon(CupertinoIcons.chart_bar, size: 48, color: Colors.grey[300]),
                                const SizedBox(height: 12),
                                Text('No data synced yet', style: TextStyle(fontSize: 17, color: Colors.grey[400])),
                                const SizedBox(height: 4),
                                Text(
                                  'Start syncing to see statistics here',
                                  style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Builder(
                          builder: (context) {
                            final sortedTypes = syncStatistics.entries.toList()
                              ..sort((a, b) => b.value.compareTo(a.value));

                            return SliverList(
                              delegate: SliverChildBuilderDelegate((context, index) {
                                final entry = sortedTypes[index];
                                final typeName = entry.key;
                                final count = entry.value;
                                final icon = _getIconForType(typeName);
                                final color = _getColorForType(typeName);

                                // Calculate percentage of total
                                final percentage = totalSyncedCount > 0 ? (count / totalSyncedCount * 100) : 0.0;

                                return Container(
                                  margin: EdgeInsets.only(
                                    left: 16,
                                    right: 16,
                                    bottom: index == sortedTypes.length - 1 ? 32 : 0,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.vertical(
                                      top: index == 0 ? const Radius.circular(16) : Radius.zero,
                                      bottom: index == sortedTypes.length - 1 ? const Radius.circular(16) : Radius.zero,
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 36,
                                              height: 36,
                                              decoration: BoxDecoration(
                                                color: color.withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Icon(icon, color: color, size: 18),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    typeName,
                                                    style: const TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w500,
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  // Progress bar
                                                  ClipRRect(
                                                    borderRadius: BorderRadius.circular(2),
                                                    child: LinearProgressIndicator(
                                                      value: percentage / 100,
                                                      backgroundColor: Colors.grey[200],
                                                      valueColor: AlwaysStoppedAnimation<Color>(color),
                                                      minHeight: 4,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              _formatNumber(count),
                                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (index < sortedTypes.length - 1)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 64),
                                          child: Divider(height: 1, color: Colors.grey[200]),
                                        ),
                                    ],
                                  ),
                                );
                              }, childCount: sortedTypes.length),
                            );
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
