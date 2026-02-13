import 'package:open_wearables_health_sdk/health_data_type.dart';
import 'package:open_wearables_health_sdk/src/config.dart';
import 'package:open_wearables_health_sdk/src/exceptions.dart';
import 'package:open_wearables_health_sdk/src/status.dart';
import 'package:open_wearables_health_sdk/src/user.dart';

import 'open_wearables_health_sdk_method_channel.dart';
import 'open_wearables_health_sdk_platform_interface.dart';

export 'package:open_wearables_health_sdk/src/config.dart';
export 'package:open_wearables_health_sdk/src/exceptions.dart';
export 'package:open_wearables_health_sdk/src/status.dart';
export 'package:open_wearables_health_sdk/src/user.dart';
export 'open_wearables_health_sdk_method_channel.dart';

/// Ensure MethodChannel is the default implementation.
/// This runs at library load time before any static methods can be called.
final OpenWearablesHealthSdkPlatform _platform = (() {
  OpenWearablesHealthSdkPlatform.instance = MethodChannelOpenWearablesHealthSdk();
  return OpenWearablesHealthSdkPlatform.instance;
})();

/// Main entry point for the Open Wearables Health SDK plugin.
///
/// This plugin enables background health data synchronization from
/// Apple HealthKit (iOS) and Health Connect (Android) to the
/// Open Wearables platform.
///
/// ## Usage
///
/// 1. Configure the plugin:
/// ```dart
/// await OpenWearablesHealthSdk.configure();
/// ```
///
/// 2. Get accessToken from your backend and sign in:
/// ```dart
/// final credentials = await yourBackend.getHealthCredentials();
/// await OpenWearablesHealthSdk.signIn(
///   userId: credentials['userId'],
///   accessToken: credentials['accessToken'],
/// );
/// ```
///
/// 3. Request health data permissions:
/// ```dart
/// await OpenWearablesHealthSdk.requestAuthorization(types: [...]);
/// ```
///
/// 4. Start background synchronization:
/// ```dart
/// await OpenWearablesHealthSdk.startBackgroundSync();
/// ```
class OpenWearablesHealthSdk {
  OpenWearablesHealthSdk._();

  static OpenWearablesHealthSdkConfig? _config;
  static OpenWearablesHealthSdkUser? _currentUser;
  static bool _isSyncActive = false;

  // MARK: - Configuration

  /// Configures the OpenWearablesHealthSdk plugin.
  ///
  /// This must be called before any other method. It will also attempt
  /// to restore any existing user session from secure storage.
  ///
  /// - [host]: The host URL for the API (e.g. `https://api.example.com`).
  ///   Only the host part — the SDK appends `/api/v1/...` paths automatically.
  ///
  /// ```dart
  /// await OpenWearablesHealthSdk.configure(
  ///   host: 'https://api.example.com',
  /// );
  ///
  /// // Check if session was restored
  /// if (OpenWearablesHealthSdk.isSignedIn) {
  ///   print('Welcome back!');
  /// }
  /// ```
  static Future<void> configure({
    required String host,
  }) async {
    _config = OpenWearablesHealthSdkConfig(host: host);

    // Configure and check if sync was auto-restored
    _isSyncActive = await _platform.configure(host: host);

    // Try to restore existing session from Keychain
    final restoredUserId = await _platform.restoreSession();
    if (restoredUserId != null) {
      _currentUser = OpenWearablesHealthSdkUser(userId: restoredUserId);
    }
  }

  /// Returns the current configuration, or null if not configured.
  static OpenWearablesHealthSdkConfig? get config => _config;

  // MARK: - Status

  /// Returns the current status of the plugin.
  static OpenWearablesHealthSdkStatus get status {
    if (_config == null) return OpenWearablesHealthSdkStatus.notConfigured;
    if (_currentUser == null) return OpenWearablesHealthSdkStatus.configured;
    return OpenWearablesHealthSdkStatus.signedIn;
  }

  /// Returns true if the plugin is configured.
  static bool get isConfigured => _config != null;

  /// Returns true if a user is signed in.
  static bool get isSignedIn => _currentUser != null;

  /// Returns the currently signed-in user, or null if no user is signed in.
  static OpenWearablesHealthSdkUser? get currentUser => _currentUser;

  /// Returns true if background sync is active.
  static bool get isSyncActive => _isSyncActive;

  // MARK: - Authentication

  /// Signs in a user with the given credentials.
  ///
  /// Two authentication modes are supported:
  ///
  /// ## Mode 1: Token-based (accessToken + refreshToken)
  ///
  /// The [accessToken] and [refreshToken] must be obtained from your backend
  /// server, which generates them via the Open Wearables API.
  ///
  /// When the server returns 401, the SDK will automatically refresh the
  /// access token using the refresh token. If refresh fails, the SDK emits
  /// an event on `MethodChannelOpenWearablesHealthSdk.authErrorStream`.
  ///
  /// ```dart
  /// final user = await OpenWearablesHealthSdk.signIn(
  ///   userId: response['userId'],
  ///   accessToken: response['accessToken'],
  ///   refreshToken: response['refreshToken'],
  /// );
  /// ```
  ///
  /// ## Mode 2: API key (apiKey)
  ///
  /// Pass [apiKey] for simple authentication using the
  /// `X-Open-Wearables-API-Key` header. On 401, the SDK emits an auth
  /// error event (no automatic token refresh for API keys).
  ///
  /// ```dart
  /// final user = await OpenWearablesHealthSdk.signIn(
  ///   userId: 'test-user',
  ///   apiKey: 'your-api-key',
  /// );
  /// ```
  ///
  /// You must provide either (accessToken + refreshToken) or (apiKey).
  ///
  /// Throws [NotConfiguredException] if [configure] was not called.
  /// Throws [SignInException] if sign-in fails.
  /// Throws [ArgumentError] if neither credential set is provided.
  static Future<OpenWearablesHealthSdkUser> signIn({
    required String userId,
    String? accessToken,
    String? refreshToken,
    String? apiKey,
  }) async {
    if (_config == null) throw const NotConfiguredException();

    final hasTokens = accessToken != null && refreshToken != null;
    final hasApiKey = apiKey != null;

    if (!hasTokens && !hasApiKey) {
      throw ArgumentError('You must provide either (accessToken + refreshToken) or (apiKey).');
    }

    await _platform.signIn(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
      apiKey: apiKey,
    );

    _currentUser = OpenWearablesHealthSdkUser(userId: userId);

    return _currentUser!;
  }

  /// Signs out the current user.
  ///
  /// This will:
  /// - Stop any background sync
  /// - Clear all tokens from secure storage (Keychain/Keystore)
  /// - Clear the user session and sync state
  ///
  /// After signing out, you must call [signIn] again before performing
  /// any sync operations.
  static Future<void> signOut() async {
    if (_currentUser != null) {
      await _platform.signOut();
      _currentUser = null;
      _isSyncActive = false;
    }
  }

  /// Updates the access token (and optionally the refresh token) for the
  /// current session without signing out and back in.
  ///
  /// Use this when:
  /// - You receive an auth error event while using a custom sync URL
  ///   and need to inject new tokens obtained from your own backend.
  /// - Your backend provides rotated tokens that you want to push
  ///   into the SDK.
  ///
  /// After updating, the SDK will automatically retry any pending
  /// uploads with the new credential.
  ///
  /// ```dart
  /// // Listen for auth errors (e.g., from custom sync URL)
  /// MethodChannelOpenWearablesHealthSdk.authErrorStream.listen((error) async {
  ///   final newTokens = await myBackend.refreshTokens();
  ///   await OpenWearablesHealthSdk.updateTokens(
  ///     accessToken: newTokens['accessToken'],
  ///     refreshToken: newTokens['refreshToken'],
  ///   );
  /// });
  /// ```
  ///
  /// Throws [NotConfiguredException] if [configure] was not called.
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<void> updateTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    _ensureSignedIn();
    await _platform.updateTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  // MARK: - Health Data Authorization

  /// Requests authorization to access the specified health data types.
  ///
  /// On iOS, this will present the HealthKit authorization sheet.
  /// On Android, this will request Health Connect permissions.
  ///
  /// Returns true if authorization was successful, false otherwise.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<bool> requestAuthorization({required List<HealthDataType> types}) async {
    _ensureSignedIn();
    return _platform.requestAuthorization(types: types.map((e) => e.id).toList(growable: false));
  }

  // MARK: - Sync Operations

  /// Starts background health data synchronization.
  ///
  /// This will:
  /// - Register for background updates when new health data is available
  /// - Perform an initial full export if this is the first sync
  /// - Schedule periodic background sync tasks
  ///
  /// The sync state is persisted and will auto-restore on app restart
  /// when [configure] is called.
  ///
  /// Returns true if background sync started successfully.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<bool> startBackgroundSync() async {
    _ensureSignedIn();
    final started = await _platform.startBackgroundSync();
    if (started) {
      _isSyncActive = true;
    }
    return started;
  }

  /// Stops background health data synchronization.
  ///
  /// This will disable all background observers and cancel scheduled tasks.
  /// The stopped state is persisted and sync will not auto-restore on restart.
  static Future<void> stopBackgroundSync() async {
    await _platform.stopBackgroundSync();
    _isSyncActive = false;
  }

  /// Manually triggers an incremental sync.
  ///
  /// This will sync any new health data since the last sync.
  /// Useful for forcing a sync when the app is in the foreground.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<void> syncNow() async {
    _ensureSignedIn();
    await _platform.syncNow();
  }

  /// Resets all sync anchors and forces a full re-export on next sync.
  ///
  /// Use this to re-sync all historical data. The next sync will
  /// behave as if it's the first sync.
  static Future<void> resetAnchors() async {
    await _platform.resetAnchors();
  }

  /// Returns stored credentials for debugging/display purposes.
  ///
  /// Returns a map with keys: userId, accessToken, refreshToken, apiKey,
  /// isSyncActive.
  /// String values may be null if not stored. isSyncActive is a bool.
  static Future<Map<String, dynamic>> getStoredCredentials() async {
    return _platform.getStoredCredentials();
  }

  // MARK: - Sync Session Management

  /// Returns the current sync session status.
  ///
  /// Use this to check if there's an interrupted sync that can be resumed.
  /// The sync will automatically resume on app restart, but you can also
  /// manually trigger resume with [resumeSync].
  ///
  /// Returns a map with:
  /// - `hasResumableSession`: bool - whether there's an interrupted sync
  /// - `sentCount`: int - number of records already sent in this session
  /// - `isFullExport`: bool - whether this is a full export or incremental
  /// - `createdAt`: String? - ISO8601 timestamp when sync started
  ///
  /// ```dart
  /// final status = await OpenWearablesHealthSdk.getSyncStatus();
  /// if (status['hasResumableSession'] == true) {
  ///   print('Sync interrupted, ${status['sentCount']} records already sent');
  /// }
  /// ```
  static Future<Map<String, dynamic>> getSyncStatus() async {
    return _platform.getSyncStatus();
  }

  /// Manually resumes an interrupted sync session.
  ///
  /// The sync is automatically resumed on app restart when [configure] is
  /// called. Use this method if you want to manually trigger resume, for
  /// example after network connectivity is restored.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  /// Throws [PlatformException] if there's no resumable session.
  ///
  /// ```dart
  /// final status = await OpenWearablesHealthSdk.getSyncStatus();
  /// if (status['hasResumableSession'] == true) {
  ///   await OpenWearablesHealthSdk.resumeSync();
  /// }
  /// ```
  static Future<void> resumeSync() async {
    _ensureSignedIn();
    await _platform.resumeSync();
  }

  /// Clears any interrupted sync session without resuming.
  ///
  /// Use this if you want to discard an interrupted sync and start fresh.
  /// This will NOT reset the sync anchors - the next sync will be incremental
  /// from where the last successful sync completed.
  ///
  /// To fully reset and re-export all data, use [resetAnchors] instead.
  static Future<void> clearSyncSession() async {
    await _platform.clearSyncSession();
  }

  // MARK: - Helpers

  static void _ensureSignedIn() {
    if (_config == null) throw const NotConfiguredException();
    if (_currentUser == null) throw const NotSignedInException();
  }
}
