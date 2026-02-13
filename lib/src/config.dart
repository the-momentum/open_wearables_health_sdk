/// Configuration for the OpenWearablesHealthSdk plugin.
class OpenWearablesHealthSdkConfig {
  const OpenWearablesHealthSdkConfig({required this.host});

  /// The host URL for the API (e.g. `https://api.example.com`).
  ///
  /// Only the host part — the SDK appends `/api/v1/...` paths automatically.
  final String host;

  @override
  String toString() => 'OpenWearablesHealthSdkConfig(host: $host)';
}
