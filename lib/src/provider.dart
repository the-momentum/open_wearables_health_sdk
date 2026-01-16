import 'dart:io';

/// Available health data providers on Android.
///
/// On iOS, only Apple HealthKit is available (no provider selection needed).
/// On Android, multiple providers may be supported.
enum AndroidHealthProvider {
  /// Samsung Health SDK - works on Samsung devices with Samsung Health app v6.30.2+
  samsungHealth('samsung_health', 'Samsung Health'),

  /// Google Health Connect - universal Android health data hub (future)
  // healthConnect('health_connect', 'Health Connect'),
  ;

  const AndroidHealthProvider(this.id, this.displayName);

  /// Internal identifier used in native code
  final String id;

  /// Human-readable display name
  final String displayName;

  /// Creates provider from its ID string
  static AndroidHealthProvider? fromId(String id) {
    for (final provider in values) {
      if (provider.id == id) return provider;
    }
    return null;
  }
}

/// Represents an available health provider on the device
class AvailableProvider {
  const AvailableProvider({
    required this.id,
    required this.displayName,
  });

  /// Internal identifier
  final String id;

  /// Human-readable display name
  final String displayName;

  /// Get the enum value if this is a known provider
  AndroidHealthProvider? get provider => AndroidHealthProvider.fromId(id);

  factory AvailableProvider.fromMap(Map<String, dynamic> map) {
    return AvailableProvider(
      id: map['id'] as String,
      displayName: map['displayName'] as String,
    );
  }

  @override
  String toString() => 'AvailableProvider($id, $displayName)';
}

/// Extension to check platform capabilities
extension HealthProviderPlatform on AndroidHealthProvider {
  /// Returns true if this provider can be used on the current platform
  bool get isAvailableOnCurrentPlatform {
    if (Platform.isIOS) {
      // iOS uses HealthKit only, no provider selection
      return false;
    }
    // On Android, provider availability is checked by native code
    return true;
  }
}
