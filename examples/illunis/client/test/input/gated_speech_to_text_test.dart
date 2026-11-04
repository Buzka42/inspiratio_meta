import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/gated_speech_to_text.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/input/mic_levels.dart';

const _rate = 16000;
const _chunkMs = 100;

/// 100 ms of a 440 Hz tone at [dbfs] peak (synthetic, no real audio).
Uint8List _tone(double dbfs) {
  final n = _rate * _chunkMs ~/ 1000;
  final a = dbfsToAmp(dbfs) * 32767;
  return pcm16ToBytes(Int16List.fromList(
      [for (var i = 0; i < n; i++) (a * math.sin(2 * math.pi * 440 * i / _rate)).round()]));
}

Uint8List _silence() => Uint8List(_rate * _chunkMs ~/ 1000 * 2);

/// Records what reaches the recogniser; answers with [reply] per call.
class RecordingStt implements SpeechToTextPort {
  RecordingStt([this.reply = const []]);
  final List<Utterance> reply;
  final received = <Int16List>[];

  @override
  Stream<Utterance> transcribe(Stream<Uint8List> audio, {required int sampleRate}) async* {
    await for (final b in audio) {
      received.add(pcm16FromBytes(b));
    }
    yield* Stream.fromIterable(reply);
  }
}

void main() {
  late List<String> logs;
  late StreamController<Uint8List> mic;
  setUp(() {
    logs = [];
    mic = StreamController<Uint8List>(sync: true);
  });

  const endpoint = EndpointTuning(trailingSilenceMs: 300, noSpeechMs: 1000, maxUtteranceMs: 3000);

  test('a too-quiet utterance is dropped before the recogniser', () async {
    final inner = RecordingStt(const [Utterance('hallucinated', isFinal: true)]);
    final gate = GatedSpeechToText(inner, endpoint: endpoint, log: logs.add);
    final out = <Utterance>[];
    final done = Completer<void>();
    gate.transcribe(mic.stream, sampleRate: _rate).listen(out.add, onDone: done.complete);
    for (var i = 0; i < 10; i++) {
      mic.add(_tone(-75)); // Below the -60 dBFS silence floor.
    }
    await done.future;
    expect(inner.received, isEmpty);
    expect(out.map((u) => (u.text, u.isFinal)), [('', true)]);
    expect(logs, ['input: utterance_dropped reason=belowFloor']);
  });

  test('a whisper is normalised once and reaches the recogniser', () async {
    final inner = RecordingStt(const [Utterance('plan my day', isFinal: true)]);
    final gate = GatedSpeechToText(inner, endpoint: endpoint, log: logs.add);
    final out = <Utterance>[];
    final done = Completer<void>();
    gate.transcribe(mic.stream, sampleRate: _rate).listen(out.add, onDone: done.complete);
    for (var i = 0; i < 2; i++) {
      mic.add(_silence()); // The room before the question is answered.
    }
    for (var i = 0; i < 6; i++) {
      mic.add(_tone(-40)); // Whisper-level voice, 600 ms.
    }
    for (var i = 0; i < 3; i++) {
      mic.add(_silence()); // Endpoint after 300 ms of silence.
    }
    await done.future;
    expect(inner.received, hasLength(1));
    final heard = inner.received.single;
    expect(heard.length, 11 * _rate * _chunkMs ~/ 1000); // 2 room + 6 voice + 3 silence
    expect(peakDbfs(heard), greaterThan(-40)); // Gain applied.
    expect(peakDbfs(heard), lessThan(-1));
    expect(out.map((u) => u.text), ['plan my day']);
    expect(logs.single, startsWith('input: utterance_kept gain_db='));
  });

  test('a steady fan does not hold the endpoint open', () async {
    final inner = RecordingStt(const [Utterance('dupa', isFinal: true)]);
    final gate = GatedSpeechToText(inner, endpoint: endpoint, log: logs.add);
    final out = <Utterance>[];
    final done = Completer<void>();
    gate.transcribe(mic.stream, sampleRate: _rate).listen(out.add, onDone: done.complete);
    for (var i = 0; i < 4; i++) {
      mic.add(_tone(-47)); // Fan at about -50 dBFS RMS, above the old fixed gate.
    }
    for (var i = 0; i < 6; i++) {
      mic.add(_tone(-30)); // Voice, 600 ms.
    }
    for (var i = 0; i < 3; i++) {
      mic.add(_silence());
    }
    await done.future;
    // 13 chunks: the endpoint closed on the silence, not on the 3 s cap.
    expect(inner.received.single.length, 13 * _rate * _chunkMs ~/ 1000);
    expect(out.map((u) => u.text), ['dupa']);
  });

  test('a recogniser with no final still ends the session', () async {
    final gate = GatedSpeechToText(RecordingStt(), endpoint: endpoint, log: logs.add);
    final out = <Utterance>[];
    final done = Completer<void>();
    gate.transcribe(mic.stream, sampleRate: _rate).listen(out.add, onDone: done.complete);
    for (var i = 0; i < 2; i++) {
      mic.add(_silence());
    }
    for (var i = 0; i < 6; i++) {
      mic.add(_tone(-30));
    }
    for (var i = 0; i < 3; i++) {
      mic.add(_silence());
    }
    await done.future;
    expect(out.map((u) => (u.text, u.isFinal)), [('', true)]);
  });

  test('cancelling the session stops reading the microphone', () async {
    final gate = GatedSpeechToText(RecordingStt(), endpoint: endpoint, log: logs.add);
    final sub = gate.transcribe(mic.stream, sampleRate: _rate).listen((_) {});
    mic.add(_tone(-30));
    expect(mic.hasListener, isTrue);
    await sub.cancel();
    expect(mic.hasListener, isFalse);
  });
}
