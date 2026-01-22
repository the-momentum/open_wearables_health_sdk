/// Represents a signed-in user in the Open Wearables system.
class OpenWearablesHealthSdkUser {
  const OpenWearablesHealthSdkUser({required this.userId});

  /// The unique user ID provided by the developer.
  final String userId;

  @override
  String toString() => 'OpenWearablesHealthSdkUser(userId: $userId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenWearablesHealthSdkUser &&
          runtimeType == other.runtimeType &&
          userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}
