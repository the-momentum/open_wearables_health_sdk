import 'package:flutter/services.dart';

import 'open_wearables_health_sdk_platform_interface.dart';
import 'src/exceptions.dart';

/// MethodChannel-based implementation of the OpenWearablesHealthSdk platform interface.
class MethodChannelOpenWearablesHealthSdk extends OpenWearablesHealthSdkPlatform {
  static const MethodChannel _channel = MethodChannel('open_wearables_health_sdk');
  static const EventChannel _logChannel = EventChannel('open_wearables_health_sdk/logs');
  static const EventChannel _authErrorChannel = EventChannel('open_wearables_health_sdk/auth_errors');

  /// Stream of log messages from the native SDK.
  /// Subscribe to this to receive real-time logs about sync operations.
  static Stream<String> get logStream => _logChannel.receiveBroadcastStream().map((event) => event.toString());

  /// Stream of authentication errors (e.g., 401 Unauthorized).
  /// Subscribe to this to handle token expiration and re-authentication.
  static Stream<Map<String, dynamic>> get authErrorStream => _authErrorChannel.receiveBroadcastStream().map((event) {
    if (event is Map) {
      return Map<String, dynamic>.from(event);
    }
    return {'statusCode': 401, 'message': 'Authentication error'};
  });

  @override
  Future<bool> configure({required String host}) async {
    await _channel.invokeMethod<void>('configure', {
      'host': host,
    });

    // Check if sync was auto-restored by querying isSyncActive
    final isSyncActive = await _channel.invokeMethod<bool>('isSyncActive');
    return isSyncActive == true;
  }

  @override
  Future<void> signIn({
    required String userId,
    String? accessToken,
    String? refreshToken,
    String? apiKey,
  }) async {
    try {
      await _channel.invokeMethod<void>('signIn', {
        'userId': userId,
        if (accessToken != null) 'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (apiKey != null) 'apiKey': apiKey,
      });
    } on PlatformException catch (e) {
      throw SignInException(e.message ?? 'Sign-in failed', statusCode: int.tryParse(e.code));
    }
  }

  @override
  Future<void> signOut() async {
    await _channel.invokeMethod<void>('signOut');
  }

  @override
  Future<void> updateTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    await _channel.invokeMethod<void>('updateTokens', {
      'accessToken': accessToken,
      if (refreshToken != null) 'refreshToken': refreshToken,
    });
  }

  @override
  Future<String?> restoreSession() async {
    final result = await _channel.invokeMethod<String?>('restoreSession');
    return result;
  }

  @override
  Future<bool> requestAuthorization({required List<String> types}) async {
    final result = await _channel.invokeMethod<bool>('requestAuthorization', {'types': types});
    return result == true;
  }

  @override
  Future<bool> startBackgroundSync() async {
    final result = await _channel.invokeMethod<bool>('startBackgroundSync');
    return result == true;
  }

  @override
  Future<void> syncNow() async {
    await _channel.invokeMethod<void>('syncNow');
  }

  @override
  Future<void> stopBackgroundSync() async {
    await _channel.invokeMethod<void>('stopBackgroundSync');
  }

  @override
  Future<void> resetAnchors() async {
    await _channel.invokeMethod<void>('resetAnchors');
  }

  @override
  Future<Map<String, dynamic>> getStoredCredentials() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('getStoredCredentials');
    if (result == null) return {};
    return result.map((key, value) => MapEntry(key as String, value));
  }

  @override
  Future<Map<String, dynamic>> getSyncStatus() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('getSyncStatus');
    if (result == null) return {};
    return result.map((key, value) => MapEntry(key as String, value));
  }

  @override
  Future<void> resumeSync() async {
    await _channel.invokeMethod<void>('resumeSync');
  }

  @override
  Future<void> clearSyncSession() async {
    await _channel.invokeMethod<void>('clearSyncSession');
  }
}
