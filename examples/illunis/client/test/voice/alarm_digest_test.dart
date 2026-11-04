import 'package:flutter_test/flutter_test.dart';

import 'package:illunis_client/voice/alarm_digest.dart';

void main() {
  const alarm = LocalTime(6, 30);
  const mon = LocalDate(2026, 10, 26);
  const tue = LocalDate(2026, 10, 27);

  bool fire(LocalTime now, LocalDate today, [LocalDate? last]) =>
      shouldFireDigest(alarm: alarm, now: now, today: today, lastFired: last);

  test('does not fire before the alarm', () {
    expect(fire(const LocalTime(6, 29), mon), isFalse);
    expect(fire(const LocalTime(0, 0), mon), isFalse);
  });

  test('fires at and shortly after the alarm', () {
    expect(fire(const LocalTime(6, 30), mon), isTrue);
    expect(fire(const LocalTime(7, 10), mon), isTrue);
  });

  test('fires once per day', () {
    expect(fire(const LocalTime(6, 31), mon, mon), isFalse);
    expect(fire(const LocalTime(8, 0), mon, mon), isFalse);
  });

  test('fires again the next day after firing yesterday', () {
    expect(fire(const LocalTime(6, 29), tue, mon), isFalse);
    expect(fire(const LocalTime(6, 30), tue, mon), isTrue);
  });

  test('skips stale digests past the catch-up window', () {
    expect(fire(const LocalTime(9, 30), mon), isTrue);
    expect(fire(const LocalTime(9, 31), mon), isFalse);
    expect(fire(const LocalTime(22, 0), mon), isFalse);
  });

  test('late alarm across midnight: next day starts fresh', () {
    const late = LocalTime(23, 50);
    expect(shouldFireDigest(alarm: late, now: const LocalTime(23, 55), today: mon), isTrue);
    // Fired Monday night; just after midnight Tuesday is before the alarm.
    expect(
      shouldFireDigest(alarm: late, now: const LocalTime(0, 5), today: tue, lastFired: mon),
      isFalse,
    );
    expect(
      shouldFireDigest(alarm: late, now: const LocalTime(23, 50), today: tue, lastFired: mon),
      isTrue,
    );
  });

  test('LocalDate equality is by value', () {
    expect(const LocalDate(2026, 1, 2), LocalDate(2026, 1, 2));
    expect(const LocalDate(2026, 1, 2) == const LocalDate(2026, 1, 3), isFalse);
  });
}
