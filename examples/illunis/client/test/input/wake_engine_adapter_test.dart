import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/input/input_fakes.dart';
import 'package:illunis_client/input/input_pipeline.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/input/wake/fake_wake_engine.dart';
import 'package:illunis_client/input/wake/wake_engine.dart';
import 'package:illunis_client/input/wake/wake_phrase.dart';
import 'package:illunis_client/input/wake_engine_adapter.dart';
import 'package:illunis_client/voice/voice_session.dart';
import 'package:illunis_client/voice/wake_keyword.dart';

/// Engine whose start throws, as SherpaWakeEngine does when model files
/// are missing.
class ThrowingWakeEngine implements WakeEngine {
  int starts = 0;
  int stops = 0;

  @override
  Stream<WakeEvent> get events => const Stream.empty();

  @override
  bool get isRunning => false;

  @override
  Future<void> start(List<WakePhrase> keywords) async {
    starts++;
    throw StateError('KWS model files missing (not bundled)');
  }

  @override
  Future<void> stop() async => stops++;
}

Future<void> settle() => pumpEventQueue();

// Synthetic fixtures only: no real audio or user speech.
void main() {
  final t0 = DateTime.utc(2026, 10, 24, 7);
  final phrase = WakePhrase.tryCreate('Hey Illunis')!;
  final keyword = WakeKeyword.tryCreate('Altair')!;
  final audio = StreamController<Uint8List>.broadcast(sync: true);

  late DateTime now;
  late FakeWakeEngine engine;
  late List<String> logs;

  WakeEngineAdapter adapter(WakeEngine e, {WakeWordPort? fallback}) => WakeEngineAdapter(
        engine: e,
        phrase: phrase,
        fallback: fallback ?? FakeWakeWordPort(const []),
        log: logs.add,
      );

  setUp(() {
    now = t0;
    engine = FakeWakeEngine(clock: () => now);
    logs = [];
  });
  tearDown(() => engine.dispose());

  group('WakeEngineAdapter', () {
    test('emits one event per accepted wake and starts the engine with the phrase',
        () async {
      final a = adapter(engine);
      final heard = <WakeWordHeard>[];
      final sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen(heard.add);
      await settle();
      expect(engine.isRunning, isTrue);
      expect(engine.keywords, [phrase]);

      expect(engine.hear('HEY_ILLUNIS'), isTrue);
      await settle();
      expect(heard, hasLength(1));

      now = t0.add(const Duration(seconds: 3));
      engine.hear('hey illunis');
      await settle();
      expect(heard, hasLength(2));
      expect(a.errorCode, isNull);
      expect(a.usingFallback, isFalse);

      await sub.cancel();
      expect(engine.isRunning, isFalse);
    });

    test('debounce holds across two rapid wakes', () async {
      final a = adapter(engine);
      final heard = <WakeWordHeard>[];
      final sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen(heard.add);
      await settle();

      engine.hear('hey illunis');
      now = t0.add(const Duration(milliseconds: 600));
      engine.hear('hey illunis');
      await settle();
      expect(heard, hasLength(1));

      // The window runs from the accepted wake, not the ignored one.
      now = t0.add(const Duration(seconds: 2));
      engine.hear('hey illunis');
      await settle();
      expect(heard, hasLength(2));
      await sub.cancel();
    });

    test('debounce holds across a restart', () async {
      final a = adapter(engine);
      final heard = <WakeWordHeard>[];
      var sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen(heard.add);
      await settle();
      engine.hear('hey illunis');
      await settle();
      await sub.cancel();

      sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen(heard.add);
      await settle();
      now = t0.add(const Duration(milliseconds: 500));
      engine.hear('hey illunis');
      await settle();
      expect(heard, hasLength(1));
      await sub.cancel();
    });

    test('start failure reports the code and falls back to the old port', () async {
      final broken = ThrowingWakeEngine();
      final legacy = FakeWakeWordPort(['noise', 'altair']);
      final a = adapter(broken, fallback: legacy);
      final heard = <WakeWordHeard>[];
      final sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen(heard.add);
      await settle();

      expect(broken.starts, 1);
      expect(a.errorCode, wakeEngineUnavailable);
      expect(a.usingFallback, isTrue);
      expect(legacy.listens, 1);
      expect(logs, ['input: wake_engine_unavailable error=StateError']);

      audio.add(Uint8List(640));
      audio.add(Uint8List(640)); // Second fragment is the old keyword.
      expect(heard, hasLength(1));
      await sub.cancel();
    });

    test('cancel before start completes leaves the engine stopped', () async {
      final a = adapter(engine);
      final sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen((_) {});
      await sub.cancel();
      await settle();
      expect(engine.isRunning, isFalse);
    });

    test('relay hands the pipeline audio to the engine', () async {
      final relay = WakeAudioRelay();
      final a = WakeEngineAdapter(
          engine: engine,
          phrase: phrase,
          fallback: FakeWakeWordPort(const []),
          audioRelay: relay,
          log: logs.add);
      expect(await relay.open().isEmpty, isTrue);
      final sub = a.listen(audio.stream, keyword, sampleRate: 16000).listen((_) {});
      await settle();
      final got = <Uint8List>[];
      final tap = relay.open().listen(got.add);
      audio.add(Uint8List(4));
      expect(got, hasLength(1));
      await tap.cancel();
      await sub.cancel();
    });
  });

  group('selectWakeWordPort', () {
    final legacy = FakeWakeWordPort(const []);
    WakeWordPort pick(String? raw) => selectWakeWordPort(
          legacy: legacy,
          enginePhrase: raw,
          buildEngine: (p) => WakeEngineAdapter(engine: engine, phrase: p, fallback: legacy),
        );

    test('keeps the old port when no phrase is set', () {
      expect(pick(null), same(legacy));
    });

    test('keeps the old port for an invalid phrase', () {
      for (final raw in ['', 'Illunis', 'hey there', 'good morning', 'hey 2 you',
          'one two three four five']) {
        expect(pick(raw), same(legacy), reason: raw);
      }
    });

    test('picks the engine for a valid phrase, normalised', () {
      final port = pick('  Hey, Illunis! ');
      expect(port, isA<WakeEngineAdapter>());
      expect((port as WakeEngineAdapter).phrase.text, 'hey illunis');
    });

    test('engineWakePhrase is null for null or rejected input', () {
      expect(engineWakePhrase(null), isNull);
      expect(engineWakePhrase('come here'), isNull);
      expect(engineWakePhrase('wake up orion')?.text, 'wake up orion');
    });
  });

  group('pipeline with the adapter', () {
    late AppController c;
    late FakeAudioCapture capture;

    InputPipeline build(WakeWordPort wake) => InputPipeline(
          controller: c,
          permission: FakeMicPermission(),
          capture: capture,
          wakeWord: wake,
          stt: FakeSpeechToText(const []),
          keyword: () => keyword,
          log: logs.add,
        );

    setUp(() {
      c = AppController(
          fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: SilentTts());
      capture = FakeAudioCapture();
    });

    test('an engine wake opens listening', () async {
      final p = build(adapter(engine));
      expect(await p.start(), isTrue);
      await settle();
      engine.hear('hey illunis');
      await settle();
      expect(c.voice, VoiceState.listening);
      await p.dispose();
      expect(engine.isRunning, isFalse);
    });

    test('a failed engine start falls back to the old keyword', () async {
      final a = adapter(ThrowingWakeEngine(), fallback: FakeWakeWordPort(['altair']));
      final p = build(a);
      expect(await p.start(), isTrue);
      await settle();
      expect(a.errorCode, wakeEngineUnavailable);
      capture.emit();
      expect(c.voice, VoiceState.listening);
      await p.dispose();
    });
  });
}
