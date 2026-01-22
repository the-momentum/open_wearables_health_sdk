/// Configuration for the OpenWearablesHealthSdk plugin.
class OpenWearablesHealthSdkConfig {
  const OpenWearablesHealthSdkConfig({this.environment = OpenWearablesHealthSdkEnvironment.production});

  /// The environment to connect to.
  final OpenWearablesHealthSdkEnvironment environment;

  /// Get the base URL for the API based on environment.
  String get baseUrl => environment.baseUrl;

  @override
  String toString() => 'OpenWearablesHealthSdkConfig(environment: ${environment.name})';
}

/// Environment for the Open Wearables platform.
enum OpenWearablesHealthSdkEnvironment {
  /// Production environment.
  production('https://open-wearables-production.up.railway.app/api/v1'),

  /// Sandbox/Development environment for testing.
  sandbox('https://sandbox.api.openwearables.io');

  const OpenWearablesHealthSdkEnvironment(this.baseUrl);

  /// The base URL for API calls.
  final String baseUrl;
}
