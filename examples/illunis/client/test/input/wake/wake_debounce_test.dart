import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/wake/wake_debounce.dart';
import 'package:illunis_client/input/wake/wake_engine.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 24, 7);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('acceptWake', () {
    test('first wake is accepted', () => expect(acceptWake(null, t0), isTrue));
    test('inside 2 s is ignored', () {
      expect(acceptWake(t0, at(0)), isFalse);
      expect(acceptWake(t0, at(1999)), isFalse);
    });
    test('at and after 2 s is accepted', () {
      expect(acceptWake(t0, at(2000)), isTrue);
      expect(acceptWake(t0, at(5000)), isTrue);
    });
    test('clock going backwards is accepted', () {
      expect(acceptWake(t0, at(-10)), isTrue);
    });
    test('custom window', () {
      expect(acceptWake(t0, at(400), window: const Duration(milliseconds: 500)), isFalse);
      expect(acceptWake(t0, at(500), window: const Duration(milliseconds: 500)), isTrue);
    });
  });

  test('debounceWakes measures from the last accepted wake', () async {
    final times = [0, 500, 1900, 2000, 2100, 3999, 4000];
    final out = await debounceWakes(
      Stream.fromIterable([for (final ms in times) WakeEvent('hey nova', at(ms))]),
    ).map((e) => e.time.difference(t0).inMilliseconds).toList();
    expect(out, [0, 2000, 4000]);
  });
}
