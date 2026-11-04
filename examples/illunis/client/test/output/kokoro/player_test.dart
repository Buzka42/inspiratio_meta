import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/output/kokoro/player.dart';

// Synthetic samples only.

final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

List<MethodCall> _mock(MethodChannel ch, [FutureOr<Object?> Function(MethodCall)? reply]) {
  final calls = <MethodCall>[];
  _messenger.setMockMethodCallHandler(ch, (c) async {
    calls.add(c);
    return reply == null ? (c.method == AudioPlayerChannel.write ? 'played' : null) : reply(c);
  });
  return calls;
}

Int16List _pcm(int n) => Int16List.fromList(List.generate(n, (i) => i - n ~/ 2));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('call order: init, write, stop, dispose', () async {
    const ch = MethodChannel('test/audio_order');
    final calls = _mock(ch);
    final p = AudioTrackPlayer(channel: ch);
    await p.play(_pcm(4), 24000);
    await p.stop();
    await p.dispose();
    expect(calls.map((c) => c.method), ['init', 'write', 'stop', 'stop', 'dispose']);
    expect(calls.first.arguments, {'sampleRate': 24000});
  });

  test('write sends little-endian Int16 bytes', () async {
    const ch = MethodChannel('test/audio_bytes');
    final calls = _mock(ch);
    await AudioTrackPlayer(channel: ch).play(Int16List.fromList([1, -2, 32767]), 24000);
    final bytes = calls[1].arguments as Uint8List;
    expect(bytes.length, 6);
    expect(ByteData.sublistView(bytes).getInt16(2, Endian.little), -2);
    expect(ByteData.sublistView(bytes).getInt16(4, Endian.little), 32767);
  });

  test('init is sent again only when the rate changes', () async {
    const ch = MethodChannel('test/audio_rate');
    final calls = _mock(ch);
    final p = AudioTrackPlayer(channel: ch);
    await p.play(_pcm(2), 24000);
    await p.play(_pcm(2), 24000);
    await p.play(_pcm(2), 22050);
    expect(calls.map((c) => c.method), ['init', 'write', 'write', 'init', 'write']);
    expect(calls[3].arguments, {'sampleRate': 22050});
  });

  test('stop completes an in-flight play at once (barge-in)', () async {
    const ch = MethodChannel('test/audio_barge');
    final native = Completer<Object?>();
    final calls = _mock(ch, (c) => c.method == AudioPlayerChannel.write ? native.future : null);
    final p = AudioTrackPlayer(channel: ch);
    var done = false;
    final play = p.play(_pcm(8), 24000).then((_) => done = true);
    await pumpEventQueue();
    expect(done, isFalse);
    await p.stop();
    await play;
    expect(done, isTrue);
    expect(calls.last.method, 'stop');
    native.complete('stopped'); // late native answer is ignored
    await pumpEventQueue();
  });

  test('missing plugin: play throws AudioPlayerUnavailable, stop and dispose do not', () async {
    const ch = MethodChannel('test/audio_missing'); // no handler
    final p = AudioTrackPlayer(channel: ch);
    await expectLater(p.play(_pcm(2), 24000), throwsA(isA<AudioPlayerUnavailable>()));
    await p.stop();
    await p.dispose();
  });

  test('native error becomes AudioPlayerFailed with the code only', () async {
    const ch = MethodChannel('test/audio_error');
    _mock(ch, (c) => c.method == AudioPlayerChannel.write
        ? throw PlatformException(code: 'internal', message: 'audio write failed')
        : null);
    await expectLater(AudioTrackPlayer(channel: ch).play(_pcm(2), 24000),
        throwsA(isA<AudioPlayerFailed>().having((e) => e.code, 'code', 'internal')));
  });

  test('play after dispose is refused', () async {
    const ch = MethodChannel('test/audio_disposed');
    _mock(ch);
    final p = AudioTrackPlayer(channel: ch);
    await p.dispose();
    expect(() => p.play(_pcm(2), 24000), throwsStateError);
  });

  test('Kotlin mirrors the channel name and methods', () {
    final kt = File('android/app/src/main/kotlin/com/illunis/illunis_client/AudioPlayerChannel.kt')
        .readAsStringSync();
    expect(kt, contains('"${AudioPlayerChannel.name}"'));
    for (final m in [
      AudioPlayerChannel.init,
      AudioPlayerChannel.write,
      AudioPlayerChannel.stop,
      AudioPlayerChannel.dispose,
    ]) {
      expect(kt, contains('"$m" ->'));
    }
    expect(kt, contains('USAGE_ASSISTANT'));
    expect(kt, contains('CONTENT_TYPE_SPEECH'));
    expect(kt, contains('MODE_STREAM'));
    expect(kt, isNot(contains('AudioRecord')));
    expect(kt, isNot(contains('startForeground')));
  });
}
