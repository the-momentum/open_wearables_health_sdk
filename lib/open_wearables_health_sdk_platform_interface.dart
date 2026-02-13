import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Defines the interface for the OpenWearablesHealthSdk plugin.
abstract class OpenWearablesHealthSdkPlatform extends PlatformInterface {
  OpenWearablesHealthSdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static OpenWearablesHealthSdkPlatform _instance = _NoopOpenWearablesHealthSdkPlatform();

  static OpenWearablesHealthSdkPlatform get instance => _instance;

  static set instance(OpenWearablesHealthSdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // MARK: - Configuration

  /// Configures the plugin with the host URL.
  /// Returns true if sync was auto-restored (session + sync was active).
  Future<bool> configure({required String host}) {
    throw UnimplementedError('configure() has not been implemented.');
  }

  // MARK: - Authentication

  /// Signs in a user with the given credentials.
  ///
  /// Two authentication modes are supported:
  ///
  /// **Mode 1: Token-based** — pass [accessToken] and [refreshToken].
  /// The SDK will use these tokens directly for API calls and will
  /// automatically refresh the access token on 401 errors.
  ///
  /// **Mode 2: API key** — pass [apiKey].
  /// The SDK will send `X-Open-Wearables-API-Key` header with each request.
  /// On 401, emits an auth error event (no automatic refresh for API keys).
  ///
  /// You must provide either (accessToken + refreshToken) or (apiKey).
  Future<void> signIn({
    required String userId,
    String? accessToken,
    String? refreshToken,
    String? apiKey,
  }) {
    throw UnimplementedError('signIn() has not been implemented.');
  }

  /// Signs out the current user and clears all tokens from secure storage.
  Future<void> signOut() {
    throw UnimplementedError('signOut() has not been implemented.');
  }

  /// Updates the access token (and optionally refresh token) for the current session.
  ///
  /// Use this after receiving an auth error event when using a custom sync URL
  /// or when your backend provides new tokens. The SDK will automatically
  /// retry any pending uploads with the new credential.
  Future<void> updateTokens({
    required String accessToken,
    String? refreshToken,
  }) {
    throw UnimplementedError('updateTokens() has not been implemented.');
  }

  /// Restores session from secure storage if available.
  ///
  /// Returns userId if session exists, null otherwise.
  Future<String?> restoreSession() {
    throw UnimplementedError('restoreSession() has not been implemented.');
  }

  // MARK: - Authorization

  /// Requests authorization from HealthKit/Health Connect.
  Future<bool> requestAuthorization({required List<String> types}) {
    throw UnimplementedError('requestAuthorization() has not been implemented.');
  }

  // MARK: - Sync Operations

  Future<bool> startBackgroundSync() {
    throw UnimplementedError('startBackgroundSync() has not been implemented.');
  }

  Future<void> syncNow() {
    throw UnimplementedError('syncNow() has not been implemented.');
  }

  Future<void> stopBackgroundSync() {
    throw UnimplementedError('stopBackgroundSync() has not been implemented.');
  }

  Future<void> resetAnchors() {
    throw UnimplementedError('resetAnchors() has not been implemented.');
  }

  /// Returns stored credentials for debugging/display purposes.
  Future<Map<String, dynamic>> getStoredCredentials() {
    throw UnimplementedError('getStoredCredentials() has not been implemented.');
  }

  /// Returns the current sync session status.
  ///
  /// Returns a map with:
  /// - hasResumableSession: bool - whether there's an interrupted sync to resume
  /// - sentCount: int - number of records already sent in this session
  /// - isFullExport: bool - whether this is a full export or incremental sync
  /// - createdAt: String? - ISO8601 timestamp when the sync session started
  Future<Map<String, dynamic>> getSyncStatus() {
    throw UnimplementedError('getSyncStatus() has not been implemented.');
  }

  /// Manually resumes an interrupted sync session.
  ///
  /// Throws if there's no resumable session.
  Future<void> resumeSync() {
    throw UnimplementedError('resumeSync() has not been implemented.');
  }

  /// Clears any interrupted sync session without resuming.
  ///
  /// Use this if you want to discard an interrupted sync and start fresh.
  Future<void> clearSyncSession() {
    throw UnimplementedError('clearSyncSession() has not been implemented.');
  }
}

/// NO-OP placeholder.
class _NoopOpenWearablesHealthSdkPlatform extends OpenWearablesHealthSdkPlatform {}
