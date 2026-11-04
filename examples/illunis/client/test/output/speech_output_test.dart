import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/output/kokoro_tts_stub.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';

// Synthetic text only.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeTtsEngine engine;
  late SpeechOutput out;
  late List<String> logs;

  setUp(() {
    engine = FakeTtsEngine();
    logs = [];
    out = SpeechOutput(engine, log: logs.add);
  });

  test('plays sentences in order and finishes', () async {
    final events = await out.speak('One. Two! Three?').toList();
    expect(engine.played, ['One.', 'Two!', 'Three?']);
    expect([for (final e in events) if (e is PlaybackStarted) (e.index, e.text)],
        [(0, 'One.'), (1, 'Two!'), (2, 'Three?')]);
    expect(events.last, isA<PlaybackFinished>());
    expect(out.isSpeaking, isFalse);
  });

  test('prepares the next sentence while the first plays', () async {
    engine.autoFinish = false;
    final events = <PlaybackEvent>[];
    out.speak('First one. Second one. Third one.').listen(events.add);
    await settle();
    // First is playing (not finished); second is already prepared; third waits.
    expect(engine.trace, ['prepare:First one.', 'prepare:Second one.', 'play:First one.']);
    expect(engine.isPlaying, isTrue);
    engine.finishPlay();
    await settle();
    expect(engine.trace.skip(3),
        ['played:First one.', 'prepare:Third one.', 'play:Second one.']);
  });

  test('cancel stops playback and ends with cancelled', () async {
    engine.autoFinish = false;
    final events = <PlaybackEvent>[];
    final done = Completer<void>();
    out.speak('A sentence. Another one.').listen(events.add, onDone: done.complete);
    await settle();
    out.cancel();
    await done.future;
    await settle();
    expect(engine.stops, 1);
    expect(engine.played, isEmpty);
    expect(engine.trace.where((t) => t.startsWith('play:')), ['play:A sentence.']);
    expect(events.last, isA<PlaybackCancelled>());
    expect(out.isSpeaking, isFalse);
  });

  test('a new speak cancels the previous one', () async {
    engine.autoFinish = false;
    final first = <PlaybackEvent>[];
    out.speak('Old words.').listen(first.add);
    await settle();
    engine.autoFinish = true;
    final second = await out.speak('New words.').toList();
    expect(first.last, isA<PlaybackCancelled>());
    expect(second.last, isA<PlaybackFinished>());
    expect(engine.played, ['New words.']);
  });

  test('synthesis failure ends with failed and logs a code only', () async {
    engine.failOn = 'Secret two.';
    final events = await out.speak('Fine one. Secret two.').toList();
    expect(engine.played, ['Fine one.']);
    expect((events.last as PlaybackFailed).code, 'synth_failed');
    expect(logs, ['speech: synth_failed']);
  });

  test('empty text finishes at once', () async {
    expect(await out.speak('  ').toList(), [isA<PlaybackFinished>()]);
  });

  test('Kokoro stub is not wired and says so', () async {
    const k = KokoroTtsEngine();
    expect((k.voiceId, k.sampleRate), ('af_heart', 24000));
    final events = await SpeechOutput(k, log: logs.add).speak('Hello.').toList();
    expect((events.single as PlaybackFailed).code, 'synth_failed');
  });
}
