import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearables_health_sdk/open_wearables_health_sdk_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('open_wearables_health_sdk');
  final platform = MethodChannelOpenWearablesHealthSdk();

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('returns true when history access is granted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestHistoryReadAuthorization');
          return true;
        });

    expect(await platform.requestHistoryReadAuthorization(), isTrue);
  });

  test('returns false when history access is denied', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestHistoryReadAuthorization');
          return false;
        });

    expect(await platform.requestHistoryReadAuthorization(), isFalse);
  });

  test('returns false when background access is denied', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestBackgroundReadAuthorization');
          return false;
        });

    expect(await platform.requestBackgroundReadAuthorization(), isFalse);
  });

  test('returns true when background access is granted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestBackgroundReadAuthorization');
          return true;
        });

    expect(await platform.requestBackgroundReadAuthorization(), isTrue);
  });
}
