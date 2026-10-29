import 'package:conest/src/radio/android_radio_link.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.conest.conest/system');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a screen-less engine tells the user to open Conest', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'needs_screen',
            message: 'Open Conest to allow this.',
          );
        });
    await expectLater(
      AndroidRadioLinks.requestBluetoothPermission(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Open Conest to allow this.',
        ),
      ),
    );
  });

  test('a channel nobody answers gives the same readable message', () async {
    await expectLater(
      AndroidRadioLinks.requestBluetoothPermission(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Open Conest'),
        ),
      ),
    );
  });

  test('a granted permission still answers true', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    expect(await AndroidRadioLinks.requestBluetoothPermission(), isTrue);
  });
}
