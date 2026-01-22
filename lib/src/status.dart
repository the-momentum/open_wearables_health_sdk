/// Represents the current status of the OpenWearablesHealthSdk plugin.
enum OpenWearablesHealthSdkStatus {
  /// Plugin has not been configured yet.
  /// Call [OpenWearablesHealthSdk.configure] first.
  notConfigured,

  /// Plugin is configured but no user is signed in.
  /// Call [OpenWearablesHealthSdk.signIn] with userId and accessToken.
  configured,

  /// User is signed in and ready to sync.
  signedIn,
}
