import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/output/kokoro/kokoro_engine.dart';
import 'package:illunis_client/output/kokoro/kokoro_factory.dart';
import 'package:illunis_client/output/kokoro/kokoro_fakes.dart';
import 'package:illunis_client/output/kokoro/player.dart';
import 'package:illunis_client/output/kokoro_tts_stub.dart' as stub;
import 'package:illunis_client/output/speech_output.dart';

// Fakes and synthetic text only. Nothing here touches native code.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeSynthBackend backend;
  late FakePcmPlayer player;
  late int loads;
  late int players;

  KokoroBuild build({bool releaseChecked = true, String voice = defaultKokoroVoice}) =>
      buildKokoroSpeech(
        '/models/kokoro',
        voice: voice,
        releaseChecked: releaseChecked,
        player: () {
          players++;
          return player;
        },
        loader: (dir, v) async {
          loads++;
          return backend;
        },
      );

  setUp(() {
    backend = FakeSynthBackend();
    player = FakePcmPlayer();
    loads = 0;
    players = 0;
  });

  group('gate off', () {
    test('default build refuses with the licence code and the stub engine', () async {
      final b = buildKokoroSpeech('/models/kokoro');
      expect(b.ready, isFalse);
      expect(b.refusal, KokoroRefusal.licence);
      expect(b.engine, isA<stub.KokoroTtsEngine>());
      await b.dispose();
    });

    test('nothing is created and speaking fails cleanly', () async {
      final b = build(releaseChecked: false);
      expect(b.refusal, 'kokoro_licence_refused');
      expect(players, 0);
      final events = await SpeechOutput(b.engine, log: (_) {}).speak('Hello there.').toList();
      expect((events.single as PlaybackFailed).code, 'synth_failed');
      expect(loads, 0);
      expect(player.played, isEmpty);
    });
  });

  test('an unknown voice is refused, not thrown', () {
    final b = build(voice: 'ef_dora');
    expect(b.refusal, KokoroRefusal.voice);
    expect(b.engine, isA<stub.KokoroTtsEngine>());
    expect(players, 0);
  });

  test('gate on with no seams uses AudioTrackPlayer', () {
    final b = buildKokoroSpeech('/models/kokoro', releaseChecked: true);
    expect(b.ready, isTrue);
    expect((b.engine as KokoroTtsEngine).player, isA<AudioTrackPlayer>());
  });

  test('gate on: plays sentences in order', () async {
    final b = build();
    expect(b.ready, isTrue);
    expect(b.engine.voiceId, 'af_heart');
    final events = await SpeechOutput(b.engine, log: (_) {}).speak('One. Two two! Three?').toList();
    expect(backend.calls, ['One.@af_heart', 'Two two!@af_heart', 'Three?@af_heart']);
    expect(player.played, [4, 8, 6]);
    expect(events.whereType<PlaybackStarted>().map((e) => e.index), [0, 1, 2]);
    expect(events.last, isA<PlaybackFinished>());
    expect(players, 1);
    expect(loads, 1);
  });

  test('stop during playback cuts the player and skips the rest', () async {
    player.autoFinish = false;
    final out = SpeechOutput(build().engine, log: (_) {});
    final events = <PlaybackEvent>[];
    final done = Completer<void>();
    out.speak('First one. Second one. Third one.').listen(events.add, onDone: done.complete);
    await settle();
    expect(player.isPlaying, isTrue);
    expect(player.played, hasLength(1));
    out.cancel(); // barge-in
    await done.future;
    await settle();
    expect(player.stops, 1);
    expect(player.isPlaying, isFalse);
    expect(player.played, hasLength(1));
    expect(backend.calls, isNot(contains('Third one.@af_heart')));
    expect(events.last, isA<PlaybackCancelled>());
  });

  test('engine stop calls player stop directly', () async {
    player.autoFinish = false;
    final e = build().engine;
    final speech = await e.prepare('Hi there.');
    var ended = false;
    final play = e.play(speech).then((_) => ended = true);
    await settle();
    expect(ended, isFalse);
    await e.stop();
    await play;
    expect(ended, isTrue);
    expect(player.stops, 1);
  });

  test('dispose releases the player and the backend, once', () async {
    final b = build();
    await (b.engine as KokoroTtsEngine).load();
    await b.dispose();
    expect(player.disposed, isTrue);
    expect(backend.disposed, isTrue);
    await b.dispose();
    await expectLater(b.engine.prepare('Hi.'), throwsStateError);
  });

  test('dispose before any load still releases the player', () async {
    final b = build();
    await b.dispose();
    expect(player.disposed, isTrue);
    expect(loads, 0);
  });

  test('dispose survives a backend that failed to load', () async {
    final e = buildKokoroSpeech(
      '/models/kokoro',
      releaseChecked: true,
      player: () => player,
      loader: (dir, v) async => throw StateError('load_failed'),
    );
    final events = await SpeechOutput(e.engine, log: (_) {}).speak('Hi.').toList();
    expect((events.single as PlaybackFailed).code, 'synth_failed');
    await e.dispose();
    expect(player.disposed, isTrue);
  });
}
