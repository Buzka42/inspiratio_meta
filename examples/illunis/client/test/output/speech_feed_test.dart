import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';

// SpeechOutput.feed: text queued over time. Synthetic text only.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeTtsEngine engine;
  late SpeechOutput out;

  setUp(() {
    engine = FakeTtsEngine(autoFinish: false);
    out = SpeechOutput(engine, log: (_) {});
  });

  List<String> plays() => [for (final t in engine.trace) if (t.startsWith('play:')) t.substring(5)];

  test('plays added text in order, one sentence at a time, then finishes on close', () async {
    final events = <PlaybackEvent>[];
    final f = out.feed();
    f.events.listen(events.add);
    f.add('First one.');
    await settle();
    expect(plays(), ['First one.']);

    f.add('Second one. Third one.');
    await settle();
    expect(plays(), ['First one.'], reason: 'the next must wait for the current to end');
    expect(engine.trace, contains('prepare:Second one.'), reason: 'prepared while the first plays');

    engine.finishPlay();
    await settle();
    expect(plays(), ['First one.', 'Second one.']);
    f.close();
    engine.finishPlay();
    await settle();
    engine.finishPlay();
    await settle();
    expect(engine.played, ['First one.', 'Second one.', 'Third one.']);
    expect([for (final e in events) if (e is PlaybackStarted) e.index], [0, 1, 2]);
    expect(events.last, isA<PlaybackFinished>());
    expect(out.isSpeaking, isFalse);
  });

  test('waits idle for text, and close with nothing queued finishes', () async {
    final f = out.feed();
    final events = <PlaybackEvent>[];
    f.events.listen(events.add);
    await settle();
    expect(out.isSpeaking, isTrue);
    expect(engine.trace, isEmpty);
    f.close();
    await settle();
    expect(events.single, isA<PlaybackFinished>());
  });

  test('dropPending skips queued sentences; the current one ends normally', () async {
    final f = out.feed();
    f.add('Playing now. Queued one. Queued two.');
    await settle();
    f.dropPending();
    f.add('Replacement.');
    f.close();
    engine.finishPlay();
    await settle();
    engine.finishPlay();
    await settle();
    expect(engine.played, ['Playing now.', 'Replacement.']);
    expect(engine.stops, 0);
  });

  test('dropPending(current: true) also stops the sentence now playing', () async {
    final f = out.feed();
    f.add('Playing now. Queued one.');
    await settle();
    f.dropPending(current: true);
    f.add('Fallback.');
    f.close();
    await settle();
    expect(engine.stops, 1);
    engine.finishPlay();
    await settle();
    expect(plays(), ['Playing now.', 'Fallback.']);
    expect(engine.played, ['Fallback.']);
  });

  test('cancel ends the feed at once; later adds do nothing', () async {
    final f = out.feed();
    final done = Completer<void>();
    final events = <PlaybackEvent>[];
    f.events.listen(events.add, onDone: done.complete);
    f.add('One sentence. Two sentence.');
    await settle();
    out.cancel();
    f.add('Too late.');
    await done.future;
    await settle();
    expect(events.last, isA<PlaybackCancelled>());
    expect(plays(), ['One sentence.']);
    expect(engine.trace, isNot(contains('prepare:Too late.')));
  });
}
