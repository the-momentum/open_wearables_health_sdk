import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_wearables_health_sdk/health_data_type.dart';
import 'package:open_wearables_health_sdk/src/config.dart';
import 'package:open_wearables_health_sdk/src/exceptions.dart';
import 'package:open_wearables_health_sdk/src/log_level.dart';
import 'package:open_wearables_health_sdk/src/provider.dart';
import 'package:open_wearables_health_sdk/src/status.dart';
import 'package:open_wearables_health_sdk/src/user.dart';

import 'open_wearables_health_sdk_method_channel.dart';
import 'open_wearables_health_sdk_platform_interface.dart';
import 'src/redeem_result.dart';

export 'package:open_wearables_health_sdk/src/config.dart';
export 'package:open_wearables_health_sdk/src/exceptions.dart';
export 'package:open_wearables_health_sdk/src/log_level.dart';
export 'package:open_wearables_health_sdk/src/provider.dart';
export 'package:open_wearables_health_sdk/src/status.dart';
export 'package:open_wearables_health_sdk/src/user.dart';
export 'open_wearables_health_sdk_method_channel.dart';
export 'src/redeem_result.dart';

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
  static OWLogLevel _logLevel = OWLogLevel.debug;
  static StreamSubscription<String>? _logSubscription;

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

    _updateLogSubscription();

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
      try {
        await _platform.signOut();
      } finally {
        _currentUser = null;
        _isSyncActive = false;
      }
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
  /// [syncDaysBack] controls how many days of historical data to sync.
  /// The SDK syncs from the **start of the day** that many days ago
  /// (inclusive), so setting 30 means all data from midnight 30 days ago
  /// until now. When `null` (the default), the SDK syncs all available
  /// history (full sync). The value is persisted and used for all
  /// subsequent background syncs until changed.
  ///
  /// Returns true if background sync started successfully.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  ///
  /// ```dart
  /// // Sync last 90 days of data
  /// await OpenWearablesHealthSdk.startBackgroundSync(syncDaysBack: 90);
  ///
  /// // Full sync (default - all available history)
  /// await OpenWearablesHealthSdk.startBackgroundSync();
  /// ```
  static Future<bool> startBackgroundSync({int? syncDaysBack}) async {
    _ensureSignedIn();
    final started = await _platform.startBackgroundSync(syncDaysBack: syncDaysBack);
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

  // MARK: - Provider Selection (Android only)

  /// Sets the health data provider on Android.
  ///
  /// On iOS this is a no-op — Apple HealthKit is the only provider.
  /// On Android you can choose between [AndroidHealthProvider.samsungHealth]
  /// and [AndroidHealthProvider.healthConnect].
  ///
  /// The provider is persisted across restarts. If never set, the SDK
  /// auto-selects the first available provider (Samsung Health preferred
  /// on Samsung devices, Health Connect elsewhere).
  ///
  /// Must be called after [configure] and before [startBackgroundSync].
  ///
  /// ```dart
  /// await OpenWearablesHealthSdk.setProvider(AndroidHealthProvider.healthConnect);
  /// ```
  static Future<void> setProvider(AndroidHealthProvider provider) async {
    await _platform.setProvider(providerId: provider.id);
  }

  /// Returns the list of health providers available on this device.
  ///
  /// On iOS this always returns an empty list. On Android it returns
  /// providers whose backing app or API is installed and meets
  /// minimum version requirements.
  ///
  /// ```dart
  /// final providers = await OpenWearablesHealthSdk.getAvailableProviders();
  /// for (final p in providers) {
  ///   print('${p.displayName} (${p.id})');
  /// }
  /// ```
  static Future<List<AvailableProvider>> getAvailableProviders() async {
    final raw = await _platform.getAvailableProviders();
    return raw.map((m) => AvailableProvider.fromMap(m)).toList();
  }

  // MARK: - Notification (Android only)

  /// Customizes the foreground notification shown during background sync
  /// on Android.
  ///
  /// Both parameters are optional — pass only what you want to change.
  /// The values are persisted and survive app restarts.
  ///
  /// On iOS this is a no-op.
  ///
  /// ```dart
  /// await OpenWearablesHealthSdk.setSyncNotification(
  ///   title: 'MyApp',
  ///   text: 'Synchronizing your fitness data...',
  /// );
  /// ```
  static Future<void> setSyncNotification({String? title, String? text}) async {
    await _platform.setSyncNotification(title: title, text: text);
  }

  // MARK: - Logging

  /// Returns the current log level.
  static OWLogLevel get logLevel => _logLevel;

  /// Sets the SDK log level. Logs are automatically printed to the
  /// Dart console (via `debugPrint`) based on this setting:
  ///
  /// - [OWLogLevel.none]:   No logs at all.
  /// - [OWLogLevel.always]: Logs are always printed.
  /// - [OWLogLevel.debug]:  Logs are printed only in debug builds (default).
  ///
  /// Call this before or after [configure]. Takes effect immediately.
  ///
  /// ```dart
  /// await OpenWearablesHealthSdk.setLogLevel(OWLogLevel.always);
  /// ```
  static Future<void> setLogLevel(OWLogLevel level) async {
    _logLevel = level;
    await _platform.setLogLevel(level: level.id);
    _updateLogSubscription();
  }

  static void _updateLogSubscription() {
    final shouldListen = switch (_logLevel) {
      OWLogLevel.none => false,
      OWLogLevel.always => true,
      OWLogLevel.debug => kDebugMode,
    };

    if (shouldListen && _logSubscription == null) {
      _logSubscription = MethodChannelOpenWearablesHealthSdk.logStream.listen(
        (message) => debugPrint('[OpenWearablesSDK] $message'),
      );
    } else if (!shouldListen && _logSubscription != null) {
      _logSubscription?.cancel();
      _logSubscription = null;
    }
  }

  // MARK: - mTLS client certificate (Android KeyChain)

  /// Prompts the user to pick a client certificate from the Android system
  /// KeyChain. The selected alias is persisted; subsequent app launches
  /// auto-install it on the SDK's HTTP client. Returns the chosen alias, or
  /// null if cancelled. Returns null immediately on non-Android platforms.
  static Future<String?> pickClientCertificate({String? hostHint}) {
    if (!Platform.isAndroid) return Future.value(null);
    return _platform.pickClientCertificate(hostHint: hostHint);
  }

  /// Returns the alias currently selected for mTLS, or null if none.
  /// Returns null immediately on non-Android platforms.
  static Future<String?> getClientCertificateAlias() {
    if (!Platform.isAndroid) return Future.value(null);
    return _platform.getClientCertificateAlias();
  }

  /// Forgets the currently selected client certificate alias.
  /// No-op on non-Android platforms.
  static Future<void> clearClientCertificate() {
    if (!Platform.isAndroid) return Future.value();
    return _platform.clearClientCertificate();
  }

  /// Redeems an invitation code through the SDK's native HTTP client, so the
  /// configured client certificate (if any) is presented during the TLS
  /// handshake. Use this instead of a Dart `http.post` when the backend is
  /// behind mTLS — the cert lives in Android KeyChain and isn't accessible
  /// from Dart's `dart:io` HttpClient. Throws [UnsupportedError] on
  /// non-Android platforms.
  static Future<RedeemResult> redeemInvitationCode({
    required String host,
    required String code,
  }) {
    if (!Platform.isAndroid) {
      throw UnsupportedError('redeemInvitationCode is only supported on Android');
    }
    return _platform.redeemInvitationCode(host: host, code: code);
  }

  // MARK: - Helpers

  static void _ensureSignedIn() {
    if (_config == null) throw const NotConfiguredException();
    if (_currentUser == null) throw const NotSignedInException();
  }
}
