import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/input/input_fakes.dart';
import 'package:illunis_client/input/input_pipeline.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/input/input_stubs.dart';
import 'package:illunis_client/input/live_mic.dart';
import 'package:illunis_client/voice/wake_keyword.dart';

/// Scripted native side: chunks and errors pushed by the test.
class ScriptedCapture implements AudioCapturePort {
  ScriptedCapture({this.startError, this.failFirstStarts = 0});
  final Object? startError;
  int failFirstStarts;
  final _out = StreamController<Uint8List>.broadcast(sync: true);
  int starts = 0;

  @override
  int get sampleRate => 16000;
  @override
  Stream<Uint8List> get chunks => _out.stream;

  @override
  Future<void> start() async {
    starts++;
    if (failFirstStarts > 0) {
      failFirstStarts--;
      throw PlatformException(code: 'not_foreground', message: 'capture starts only from the open app');
    }
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stop() async {}

  void push(int tag) => _out.add(Uint8List.fromList([tag, 0]));
  void fail() => _out.addError(PlatformException(code: 'mic_unavailable', message: 'capture failed'));
}

// Synthetic data only: no real audio.
void main() {
  late List<String> logs;
  setUp(() => logs = []);

  test('adapter forwards chunks in order', () async {
    final native = ScriptedCapture();
    final cap = SafeAudioCapture(native, log: logs.add);
    final got = <int>[];
    final sub = cap.chunks.listen((c) => got.add(c.first));
    await cap.start();
    for (final t in [1, 2, 3, 4, 5]) {
      native.push(t);
    }
    expect(got, [1, 2, 3, 4, 5]);
    expect(cap.sampleRate, 16000);
    expect(logs, isEmpty);
    await sub.cancel();
  });

  test('a stream error logs mic_unavailable and later chunks still pass', () async {
    final native = ScriptedCapture();
    final cap = SafeAudioCapture(native, log: logs.add);
    final got = <int>[];
    final errors = <Object>[];
    final sub = cap.chunks.listen((c) => got.add(c.first), onError: errors.add);
    native.push(1);
    native.fail();
    native.push(2);
    expect(got, [1, 2]);
    expect(errors, isEmpty);
    expect(logs, ['input: mic_unavailable']);
    await sub.cancel();
  });

  test('a start failure logs the code only and throws MicUnavailable', () async {
    final native = ScriptedCapture(
        startError: PlatformException(code: 'internal', message: 'secret detail /data/path'));
    final cap = SafeAudioCapture(native, log: logs.add);
    await expectLater(cap.start(), throwsA(isA<MicUnavailable>()));
    expect(logs, ['input: mic_unavailable']);
    expect(logs.join(), isNot(contains('secret')));
    expect(logs.join(), isNot(contains('internal')));
  });

  test('not_foreground is retried once', () async {
    final native = ScriptedCapture(failFirstStarts: 1);
    final cap = SafeAudioCapture(native, log: logs.add, retryDelay: Duration.zero);
    await cap.start();
    expect(native.starts, 2);
    expect(logs, isEmpty);
  });

  test('granted gives the live capture and does not ask again', () async {
    final perm = FakeMicPermission(MicPermission.granted);
    final native = ScriptedCapture();
    final ports = await resolveMicPorts(permission: perm, live: () => native, log: logs.add);
    expect(ports.live, isTrue);
    expect(ports.capture, same(native));
    expect(await ports.permission.request(), MicPermission.granted);
    expect(perm.requests, 1);
    expect(logs, isEmpty);
  });

  test('a denied permission keeps the stubs with a logged code', () async {
    var built = 0;
    final ports = await resolveMicPorts(
        permission: FakeMicPermission(MicPermission.denied),
        live: () {
          built++;
          return ScriptedCapture();
        },
        log: logs.add);
    expect(ports.live, isFalse);
    expect(built, 0);
    expect(ports.capture, isA<StubAudioCapture>());
    expect(ports.permission, isA<StubMicPermission>());
    expect(logs, ['input: mic_fallback code=mic_denied']);
  });

  test('a throwing permission port keeps the stubs as unavailable', () async {
    final ports = await resolveMicPorts(
        permission: _ThrowingPermission(), live: ScriptedCapture.new, log: logs.add);
    expect(ports.live, isFalse);
    expect(logs, ['input: mic_fallback code=mic_unavailable']);
  });

  group('pipeline', () {
    late AppController c;
    setUp(() => c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: SilentTts()));

    InputPipeline build(MicPorts ports) => InputPipeline(
          controller: c,
          permission: ports.permission,
          capture: ports.capture,
          wakeWord: FakeWakeWordPort(const []),
          stt: FakeSpeechToText(const []),
          keyword: () => WakeKeyword.tryCreate('Altair'),
          log: logs.add,
        );

    test('denied: pipeline stays off on the stubs, no throw', () async {
      final ports = await resolveMicPorts(
          permission: FakeMicPermission(MicPermission.denied),
          live: ScriptedCapture.new,
          log: logs.add);
      final p = build(ports);
      expect(await p.start(), isFalse);
      expect(p.status, InputStatus.denied);
      expect(logs, ['input: mic_fallback code=mic_denied', 'input: mic_unavailable']);
    });

    test('start failure: pipeline fails with codes only, app keeps running', () async {
      final ports = await resolveMicPorts(
          permission: FakeMicPermission(),
          live: () => SafeAudioCapture(
              ScriptedCapture(startError: PlatformException(code: 'busy', message: 'detail')),
              log: logs.add),
          log: logs.add);
      final p = build(ports);
      expect(await p.start(), isFalse);
      expect(p.status, InputStatus.failed);
      expect(p.errorCode, 'mic_start_failed');
      expect(logs, ['input: mic_unavailable', 'input: mic_start_failed error=MicUnavailable']);
    });

    test('granted: live chunks reach the wake port in order', () async {
      final native = ScriptedCapture();
      final ports = await resolveMicPorts(
          permission: FakeMicPermission(),
          live: () => SafeAudioCapture(native, log: logs.add),
          log: logs.add);
      final seen = <int>[];
      final p = InputPipeline(
        controller: c,
        permission: ports.permission,
        capture: ports.capture,
        wakeWord: _RecordingWake(seen),
        stt: FakeSpeechToText(const []),
        keyword: () => WakeKeyword.tryCreate('Altair'),
        log: logs.add,
      );
      expect(await p.start(), isTrue);
      for (final t in [7, 8, 9]) {
        native.push(t);
      }
      expect(seen, [7, 8, 9]);
      await p.dispose();
    });
  });
}

class _ThrowingPermission implements MicPermissionPort {
  @override
  Future<MicPermission> request() async => throw StateError('no');
}

class _RecordingWake implements WakeWordPort {
  _RecordingWake(this.seen);
  final List<int> seen;

  @override
  Stream<Never> listen(Stream<Uint8List> audio, WakeKeyword keyword, {required int sampleRate}) {
    late final StreamController<Never> out;
    StreamSubscription<Uint8List>? sub;
    out = StreamController<Never>(
      sync: true,
      onListen: () => sub = audio.listen((c) => seen.add(c.first)),
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }
}
