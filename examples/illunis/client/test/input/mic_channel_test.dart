import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/input/mic_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('illunis/mic');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(ch, null));

  void answer(Object? Function(MethodCall c) f) =>
      messenger.setMockMethodCallHandler(ch, (c) async => f(c));

  test('permission maps granted, denied and errors', () async {
    answer((_) => 'granted');
    expect(await ChannelMicPermission().request(), MicPermission.granted);
    answer((_) => 'denied');
    expect(await ChannelMicPermission().request(), MicPermission.denied);
    answer((_) => throw PlatformException(code: 'busy'));
    expect(await ChannelMicPermission().request(), MicPermission.unavailable);
  });

  test('capture calls start, stop and captureInfo', () async {
    final calls = <String>[];
    answer((c) {
      calls.add(c.method);
      return c.method == 'captureInfo' ? {'source': 'voice_recognition', 'nsEnabled': false} : null;
    });
    final cap = ChannelAudioCapture();
    expect(cap.sampleRate, 16000);
    await cap.start();
    expect((await cap.captureInfo())['source'], 'voice_recognition');
    await cap.stop();
    expect(calls, ['startCapture', 'captureInfo', 'stopCapture']);
  });
}
