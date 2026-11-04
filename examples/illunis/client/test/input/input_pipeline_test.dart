import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/core/mode_controller.dart';
import 'package:illunis_client/input/input_fakes.dart';
import 'package:illunis_client/input/input_pipeline.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/voice/voice_session.dart';
import 'package:illunis_client/voice/wake_keyword.dart';

// Synthetic fixtures only: no real audio or user speech.
void main() {
  late SilentTts tts;
  late AppController c;
  late List<TurnRequest> turns;
  late FakeMicPermission mic;
  late FakeAudioCapture capture;
  late FakeWakeWordPort wake;
  late FakeSpeechToText stt;
  late List<String> logs;
  final keyword = WakeKeyword.tryCreate('Altair');

  InputPipeline build() => InputPipeline(
        controller: c,
        permission: mic,
        capture: capture,
        wakeWord: wake,
        stt: stt,
        keyword: () => keyword,
        log: logs.add,
      );

  setUp(() {
    tts = SilentTts();
    c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: tts);
    turns = [];
    c.turnRequests.listen(turns.add);
    mic = FakeMicPermission();
    capture = FakeAudioCapture();
    wake = FakeWakeWordPort(const []);
    stt = FakeSpeechToText(const []);
    logs = [];
  });

  test('wake then utterance reaches handleUtterance', () async {
    wake.addFragments(['the', 'altair.']);
    stt.addUtterances(const [Utterance('plan'), Utterance('plan my day', isFinal: true)]);
    final p = build();
    expect(await p.start(), isTrue);
    expect(p.status, InputStatus.running);

    capture.emit(2); // Second fragment is the keyword.
    expect(c.voice, VoiceState.listening);
    expect(p.sessionOpen, isTrue);

    capture.emit(2); // Partial, then final.
    expect(turns.map((t) => t.text), ['plan my day']);
    expect(c.voice, VoiceState.thinking);
    await p.dispose();
  });

  test('mode command ends the session when the voice state goes idle', () async {
    wake.addFragments(['Altair!']);
    stt.addUtterances(const [Utterance('show me the sky', isFinal: true)]);
    final p = build();
    await p.start();
    capture.emit(); // Wake.
    capture.emit(); // Final transcript.
    expect(c.mode, GraphicMode.classic);
    expect(c.voice, VoiceState.idle);
    expect(p.sessionOpen, isFalse);
    expect(stt.sessionsClosed, 1);
    expect(turns, isEmpty);
    await p.dispose();
  });

  test('a non-keyword fragment does not wake', () async {
    wake.addFragments(['vega.', 'hey altair', 'altairs']);
    stt.addUtterances(const [Utterance('plan my day', isFinal: true)]);
    final p = build();
    await p.start();
    capture.emit(3);
    expect(c.voice, VoiceState.idle);
    expect(stt.sessionsOpened, 0);
    expect(turns, isEmpty);
    await p.dispose();
  });

  test('speech while speaking is a barge-in', () async {
    wake.addFragments(['altair']);
    stt.addUtterances(const [
      Utterance('tell me a story', isFinal: true),
      Utterance(''), // Silence while Illunis speaks: no barge-in.
      Utterance('stop'),
      Utterance('stop please', isFinal: true),
    ]);
    final p = build();
    await p.start();
    capture.emit(2);
    expect(c.voice, VoiceState.thinking);
    c.dispatch(const ReplyChunk('Once upon a time'));
    expect(c.voice, VoiceState.speaking);

    capture.emit(); // Empty partial.
    expect(c.voice, VoiceState.speaking);
    expect(tts.stops, 0);

    capture.emit(); // User speaks.
    expect(c.voice, VoiceState.listening);
    expect(tts.stops, 1); // BargeIn stopped playback.
    expect(p.sessionOpen, isTrue);

    capture.emit(); // The interrupting request becomes the next turn.
    expect(turns.map((t) => t.text), ['tell me a story', 'stop please']);
    await p.dispose();
  });

  test('wake word while speaking is also a barge-in', () async {
    wake.addFragments(['altair', 'x', 'Altair.']);
    stt.addUtterances(const [Utterance('hi there', isFinal: true)]);
    final p = build();
    await p.start();
    capture.emit(2);
    c.dispatch(const ReplyChunk('Hello'));
    capture.emit();
    expect(c.voice, VoiceState.listening);
    expect(tts.stops, 1);
    await p.dispose();
  });

  test('mic denied stays off with mic_denied and no crash', () async {
    mic.answer = MicPermission.denied;
    final p = build();
    expect(await p.start(), isFalse);
    expect(p.status, InputStatus.denied);
    expect(p.errorCode, 'mic_denied');
    expect(capture.starts, 0);
    expect(capture.emit(), 0);
    c.dispatch(const WakeWordHeard()); // Alarm path still works, no session.
    expect(p.sessionOpen, isFalse);
    expect(logs, ['input: mic_denied']);
    await p.dispose();
  });

  test('unavailable mic and failing capture report codes', () async {
    mic.answer = MicPermission.unavailable;
    final p = build();
    expect(await p.start(), isFalse);
    expect(p.errorCode, 'mic_unavailable');

    final broken = InputPipeline(
      controller: c,
      permission: FakeMicPermission(),
      capture: _ThrowingCapture(),
      wakeWord: wake,
      stt: stt,
      keyword: () => keyword,
      log: logs.add,
    );
    expect(await broken.start(), isFalse);
    expect(broken.status, InputStatus.failed);
    expect(broken.errorCode, 'mic_start_failed');
    await p.dispose();
    await broken.dispose();
  });

  test('dispose stops capture and closes the session', () async {
    wake.addFragments(['altair']);
    final p = build();
    await p.start();
    expect(capture.capturing, isTrue);
    capture.emit();
    expect(stt.sessionOpen, isTrue);

    await p.dispose();
    expect(capture.capturing, isFalse);
    expect(capture.stops, 1);
    expect(stt.sessionOpen, isFalse);
    expect(p.status, InputStatus.disposed);
    expect(await p.start(), isFalse);
  });

  test('StartListening without a wake (alarm tap) opens a session', () async {
    stt.addUtterances(const [Utterance('good morning plan', isFinal: true)]);
    final p = InputPipeline(
      controller: c,
      permission: mic,
      capture: capture,
      wakeWord: wake,
      stt: stt,
      keyword: () => null, // Interview not done yet.
      log: logs.add,
    );
    await p.start();
    expect(logs, contains('input: wake_off reason=no_keyword'));
    c.dispatch(const WakeWordHeard()); // What the alarm coordinator sends.
    expect(p.sessionOpen, isTrue);
    capture.emit();
    expect(turns.single.text, 'good morning plan');
    await p.dispose();
  });

  test('logs carry codes only, never transcripts', () async {
    wake.addFragments(['altair']);
    stt.addUtterances(const [Utterance('private words', isFinal: true)]);
    final p = build();
    await p.start();
    capture.emit(2);
    await p.dispose();
    expect(logs.where((l) => l.contains('private')), isEmpty);
  });
}

class _ThrowingCapture extends FakeAudioCapture {
  @override
  Future<void> start() async => throw StateError('no mic');
}
