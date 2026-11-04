import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/gated_speech_to_text.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/input/input_stubs.dart';
import 'package:illunis_client/input/mic_levels.dart';
import 'package:illunis_client/input/stt/sherpa_whisper_stt.dart';
import 'package:illunis_client/input/stt/whisper_model.dart';
import 'package:illunis_client/input/stt/whisper_recogniser.dart';

const _rate = 16000;
const _chunkMs = 100;
const _endpoint = EndpointTuning(trailingSilenceMs: 300, noSpeechMs: 1000, maxUtteranceMs: 3000);

/// 100 ms of a 440 Hz tone at [dbfs] peak (synthetic, no real audio).
Uint8List _tone(double dbfs) {
  final n = _rate * _chunkMs ~/ 1000;
  final a = dbfsToAmp(dbfs) * 32767;
  return pcm16ToBytes(Int16List.fromList(
      [for (var i = 0; i < n; i++) (a * math.sin(2 * math.pi * 440 * i / _rate)).round()]));
}

Uint8List _silence() => Uint8List(_rate * _chunkMs ~/ 1000 * 2);

/// Answers each call with the next text, or throws [error].
class FakeRecogniser implements WhisperRecogniser {
  FakeRecogniser(this.texts, {this.error});
  final List<String> texts;
  final Object? error;
  final received = <Float32List>[];
  var disposed = false;

  @override
  Future<String> recognise(Float32List samples, int sampleRate) async {
    received.add(samples);
    await Future<void>.delayed(Duration.zero); // Like a worker round trip.
    if (error != null) throw error!;
    return texts[received.length - 1];
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// One whispered session through the gate; returns what the gate emitted.
Future<List<Utterance>> _session(SpeechToTextPort gate) async {
  final mic = StreamController<Uint8List>(sync: true);
  final out = <Utterance>[];
  final done = Completer<void>();
  gate.transcribe(mic.stream, sampleRate: _rate).listen(out.add, onDone: done.complete);
  for (var i = 0; i < 2; i++) {
    mic.add(_silence()); // The room before the question is answered.
  }
  for (var i = 0; i < 6; i++) {
    mic.add(_tone(-40));
  }
  for (var i = 0; i < 3; i++) {
    mic.add(_silence());
  }
  await done.future;
  await mic.close();
  return out;
}

void main() {
  late List<String> logs;
  setUp(() => logs = []);

  const texts = ['plan my day', 'set an alarm for six forty five'];

  test('transcripts reach the gate output in order, one final per utterance', () async {
    final fake = FakeRecogniser(texts);
    final stt = SherpaWhisperStt(recogniser: fake, fallback: StubSpeechToText(), log: logs.add);
    final gate = GatedSpeechToText(stt, endpoint: _endpoint, log: logs.add);

    final first = await _session(gate);
    final second = await _session(gate);

    expect(first.map((u) => (u.text, u.isFinal)), [(texts[0], true)]);
    expect(second.map((u) => (u.text, u.isFinal)), [(texts[1], true)]);
    expect(fake.received, hasLength(2));
    // One normalised 16 kHz float buffer: 1100 ms (200 ms room, 600 ms voice, 300 ms silence), gain applied, no clipping.
    final heard = fake.received.first;
    expect(heard.length, 11 * _rate * _chunkMs ~/ 1000);
    final peak = heard.fold<double>(0, (m, s) => math.max(m, s.abs()));
    expect(peak, greaterThan(dbfsToAmp(-40)));
    expect(peak, lessThan(1.0));
  });

  test('logs carry codes and numbers only, never the transcript', () async {
    final fake = FakeRecogniser(texts);
    final stt = SherpaWhisperStt(recogniser: fake, fallback: StubSpeechToText(), log: logs.add);
    await _session(GatedSpeechToText(stt, endpoint: _endpoint, log: logs.add));

    expect(logs, hasLength(2));
    expect(logs[0], startsWith('input: utterance_kept gain_db='));
    expect(logs[1], matches(RegExp(r'^input: stt_done audio_ms=1100 proc_ms=\d+ empty=false$')));
    for (final line in logs) {
      for (final word in texts.first.split(' ')) {
        expect(line.contains(word), isFalse, reason: 'transcript word in log: $line');
      }
    }
  });

  test('a failed decode logs its code and falls back to the stub', () async {
    final fake = FakeRecogniser(texts, error: const WhisperFailure(sttDecodeFailed, 'x'));
    final stt = SherpaWhisperStt(recogniser: fake, fallback: StubSpeechToText(), log: logs.add);
    final out = await _session(GatedSpeechToText(stt, endpoint: _endpoint, log: logs.add));

    // The stub emits nothing, so the gate ends the session with an empty final.
    expect(out.map((u) => (u.text, u.isFinal)), [('', true)]);
    expect(logs.last, 'input: stt_failed code=$sttDecodeFailed');
  });

  test('an unexpected recogniser error logs a generic code', () async {
    final fake = FakeRecogniser(texts, error: StateError('native detail'));
    final stt = SherpaWhisperStt(recogniser: fake, fallback: StubSpeechToText(), log: logs.add);
    await _session(GatedSpeechToText(stt, endpoint: _endpoint, log: logs.add));
    expect(logs.last, 'input: stt_failed code=stt_error');
  });

  group('model check', () {
    const dir = '/support/models/stt/$whisperModelName';

    test('the model directory and int8 file names match eval/stt', () {
      expect(whisperModelDir('/support/'), dir);
      expect(WhisperModel.inDir(dir).files, [
        '$dir/tiny.en-encoder.int8.onnx',
        '$dir/tiny.en-decoder.int8.onnx',
        '$dir/tiny.en-tokens.txt',
      ]);
    });

    test('fromDir throws a clear model-missing error naming the files', () {
      expect(
        () => SherpaWhisperStt.fromDir(dir,
            fallback: StubSpeechToText(),
            exists: (p) => !p.endsWith('tokens.txt'),
            build: (_) => fail('must not load native code')),
        throwsA(isA<WhisperFailure>()
            .having((e) => e.code, 'code', sttModelMissing)
            .having((e) => e.detail, 'detail', contains('tiny.en-tokens.txt'))),
      );
    });

    test('a missing model falls back to the stub with a code', () {
      final stub = StubSpeechToText();
      final port = chooseSpeechToText(
          fallback: stub,
          modelDir: dir,
          exists: (_) => false,
          build: (_) => fail('must not load native code'),
          log: logs.add);
      expect(port, same(stub));
      expect(logs, ['input: stt_engine_off code=$sttModelMissing']);
    });

    test('a present model gives the Whisper adapter', () {
      WhisperModel? built;
      final port = chooseSpeechToText(
          fallback: StubSpeechToText(),
          modelDir: dir,
          exists: (_) => true,
          build: (m) {
            built = m;
            return FakeRecogniser(texts);
          },
          log: logs.add);
      expect(port, isA<SherpaWhisperStt>());
      expect(built?.encoder, '$dir/tiny.en-encoder.int8.onnx');
      expect(logs, ['input: stt_engine_on']);
    });

    test('a build that throws falls back with a load code', () {
      final stub = StubSpeechToText();
      final port = chooseSpeechToText(
          fallback: stub,
          modelDir: dir,
          exists: (_) => true,
          build: (_) => throw StateError('boom'),
          log: logs.add);
      expect(port, same(stub));
      expect(logs, ['input: stt_engine_off code=$sttLoadFailed']);
    });
  });

  test('pcm16 bytes become floats in [-1, 1)', () {
    final f = pcm16BytesToFloat32(pcm16ToBytes(Int16List.fromList([0, 16384, -32768, 32767])));
    expect(f, [0.0, 0.5, -1.0, closeTo(1.0, 1e-4)]);
    expect(pcm16BytesToFloat32(Uint8List(3)), hasLength(1)); // Odd byte dropped.
  });
}
