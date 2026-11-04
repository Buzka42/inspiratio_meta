import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/wake/fake_wake_engine.dart';
import 'package:illunis_client/input/wake/wake_debounce.dart';
import 'package:illunis_client/input/wake/wake_engine.dart';
import 'package:illunis_client/input/wake/wake_phrase.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 24, 7);
  final nova = WakePhrase.tryCreate('Hey Nova')!;
  final orion = WakePhrase.tryCreate('wake up orion')!;

  late FakeWakeEngine engine;
  setUp(() => engine = FakeWakeEngine(clock: () => t0));
  tearDown(() => engine.dispose());

  test('emits an event with keyword and time for a started phrase', () async {
    final events = <WakeEvent>[];
    final sub = engine.events.listen(events.add);
    await engine.start([nova, orion]);
    expect(engine.isRunning, isTrue);
    expect(engine.hear('HEY_NOVA'), isTrue);
    expect(engine.hear('wake up, Orion!'), isTrue);
    expect(engine.hear('hello nova'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(events, [WakeEvent('hey nova', t0), WakeEvent('wake up orion', t0)]);
    await sub.cancel();
  });

  test('emits nothing before start or after stop', () async {
    final events = <WakeEvent>[];
    final sub = engine.events.listen(events.add);
    expect(engine.hear('hey nova'), isFalse);
    await engine.start([nova]);
    await engine.stop();
    expect(engine.isRunning, isFalse);
    expect(engine.hear('hey nova'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    await sub.cancel();
  });

  test('start replaces the keyword set and rejects an empty list', () async {
    await engine.start([nova]);
    await engine.start([orion]);
    expect(engine.keywords, [orion]);
    expect(engine.hear('hey nova'), isFalse);
    expect(() => engine.start(const []), throwsArgumentError);
  });

  test('debounced engine output drops a second wake within 2 s', () async {
    final out = <int>[];
    final sub = debounceWakes(engine.events)
        .listen((e) => out.add(e.time.difference(t0).inMilliseconds));
    await engine.start([nova]);
    for (final ms in [0, 1200, 2500]) {
      engine.hear('hey nova', at: t0.add(Duration(milliseconds: ms)));
    }
    await Future<void>.delayed(Duration.zero);
    expect(out, [0, 2500]);
    await sub.cancel();
  });
}
