/// Typed result returned by [OpenWearablesHealthSdk.redeemInvitationCode].
class RedeemResult {
  final int statusCode;
  final String body;
  final Map<String, dynamic> data;

  const RedeemResult({
    required this.statusCode,
    required this.body,
    required this.data,
  });

  factory RedeemResult.fromMap(Map<Object?, Object?> map) {
    final rawData = map['data'];
    return RedeemResult(
      statusCode: map['statusCode'] as int? ?? 0,
      body: map['body'] as String? ?? '',
      data: rawData is Map ? rawData.cast<String, dynamic>() : const {},
    );
  }
}
