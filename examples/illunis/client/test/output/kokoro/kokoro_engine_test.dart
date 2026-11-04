import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/output/kokoro/kokoro_engine.dart';
import 'package:illunis_client/output/kokoro/kokoro_fakes.dart';
import 'package:illunis_client/output/kokoro/kokoro_licence.dart';
import 'package:illunis_client/output/kokoro/kokoro_voices.dart';
import 'package:illunis_client/output/kokoro/sherpa_backend.dart';
import 'package:illunis_client/output/kokoro/synth_backend.dart';
import 'package:illunis_client/output/kokoro_tts_stub.dart' as stub;
import 'package:illunis_client/output/speech_output.dart';

// Synthetic text only.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeSynthBackend backend;
  late FakePcmPlayer player;
  late int loads;

  KokoroTtsEngine engine({String voice = defaultKokoroVoice}) => KokoroTtsEngine(
    '/models/kokoro',
    voice: voice,
    player: player,
    loader: (dir, v) async {
      loads++;
      return backend;
    },
  );

  setUp(() {
    backend = FakeSynthBackend(sampleRate: 24000);
    player = FakePcmPlayer();
    loads = 0;
  });

  test('default voice is af_heart, sid 3', () {
    final e = engine();
    expect(e.voiceId, 'af_heart');
    expect(e.voice.sid, 3);
    expect(defaultKokoroVoice, 'af_heart');
  });

  test('voice list is English only and names are unique', () {
    final names = kokoroEnglishVoices.map((v) => v.name).toList();
    expect(names.toSet().length, names.length);
    expect(names.every((n) => RegExp(r'^[ab][fm]_').hasMatch(n)), isTrue);
    expect(kokoroVoice('bf_emma').sid, 21);
  });

  test('rejects a non-English or unknown voice', () {
    expect(() => engine(voice: 'ef_dora'), throwsArgumentError);
    expect(() => engine(voice: 'nope'), throwsArgumentError);
  });

  test('synthesises sentence by sentence, in order, and reports the rate', () async {
    final out = SpeechOutput(engine(), log: (_) {});
    final events = await out.speak('One. Two two! Three?').toList();
    expect(backend.calls, ['One.@af_heart', 'Two two!@af_heart', 'Three?@af_heart']);
    expect(player.played, [4, 8, 6]);
    expect(events.last, isA<PlaybackFinished>());
    expect(loads, 1);
  });

  test('sample rate comes from the backend once loaded', () async {
    backend = FakeSynthBackend(sampleRate: 22050);
    final e = engine();
    expect(e.sampleRate, kokoroDefaultSampleRate);
    await e.load();
    expect(e.sampleRate, 22050);
    final s = await e.prepare('Hi.') as KokoroSpeech;
    expect(s.sampleRate, 22050);
    expect(s.pcm16, everyElement(16384));
  });

  test('a cancelled speak stops before the next sentence', () async {
    player.autoFinish = false;
    final out = SpeechOutput(engine(), log: (_) {});
    final events = <PlaybackEvent>[];
    final done = Completer<void>();
    out.speak('First one. Second one. Third one.').listen(events.add, onDone: done.complete);
    await settle();
    expect(player.played, hasLength(1));
    out.cancel();
    await done.future;
    await settle();
    expect(player.stops, 1);
    expect(player.played, hasLength(1));
    expect(backend.calls, isNot(contains('Third one.@af_heart')));
    expect(events.whereType<PlaybackStarted>().map((e) => e.index), [0]);
    expect(events.last, isA<PlaybackCancelled>());
  });

  group('licence gate', () {
    test('the release flag defaults to off', () {
      expect(kokoroGplCheckedFlag, isFalse);
      expect(checkKokoroLicence, throwsA(isA<KokoroLicenceRefused>()));
      expect(() => checkKokoroLicence(releaseChecked: true), returnsNormally);
    });

    test('the real backend refuses to start by default', () async {
      await expectLater(
        SherpaKokoroBackend.load('/models/kokoro', kokoroVoice(defaultKokoroVoice)),
        throwsA(isA<KokoroLicenceRefused>()),
      );
    });

    test('a default engine fails to speak with synth_failed', () async {
      final e = KokoroTtsEngine('/models/kokoro', player: player);
      await expectLater(e.load(), throwsA(isA<KokoroLicenceRefused>()));
      final logs = <String>[];
      final events = await SpeechOutput(e, log: logs.add).speak('Hello there.').toList();
      expect(events.single, isA<PlaybackFailed>());
      expect((events.single as PlaybackFailed).code, 'synth_failed');
      expect(player.played, isEmpty);
    });
  });

  test('pcm conversion clamps', () {
    final pcm = toPcm16(Float32List.fromList([-2, -1, 0, 1, 2]));
    expect(pcm, [-32767, -32767, 0, 32767, 32767]);
  });

  test('the old stub still behaves as before', () async {
    const s = stub.KokoroTtsEngine();
    expect(s.voiceId, 'af_heart');
    await expectLater(s.prepare('Hi.'), throwsUnsupportedError);
  });

  test('dispose releases the backend', () async {
    final e = engine();
    await e.load();
    await e.dispose();
    expect(backend.disposed, isTrue);
  });
}
