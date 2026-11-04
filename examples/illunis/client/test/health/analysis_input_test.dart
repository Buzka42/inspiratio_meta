import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/health/analysis_input.dart';
import 'package:illunis_client/health/checkin.dart';
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/health/health_port.dart';

// The /analysis/21d body. Generated synthetic history only.
final today = DateTime(2026, 10, 25, 9);

String d(int back) => dayKey(DateTime(2026, 10, 25 - back));

List<DailySignals> synthSignals(int n) => [
      for (var i = n - 1; i >= 0; i--)
        DailySignals(day: d(i), sleepMinutes: 400 + i, steps: 6000 + 10 * i, restingHr: 56 + i % 3),
    ];

void main() {
  test('dayKey and parseDayKey round-trip; impossible dates are null', () {
    expect(dayKey(DateTime(2026, 3, 7)), '2026-03-07');
    expect(parseDayKey('2026-03-07'), DateTime(2026, 3, 7));
    expect(parseDayKey('2026-02-30'), isNull);
    expect(parseDayKey(7), isNull);
  });

  test('window keeps the 21 days ending today, oldest first, empty days out', () {
    final input = AnalysisInput.window(
      checkins: [
        CheckIn(day: d(25), mood: 1), // Too old.
        CheckIn(day: d(0), mood: 4, energy: 3, sleep: 5),
        CheckIn(day: d(3), mood: 2, energy: 2, sleep: 2),
        CheckIn(day: d(-1), mood: 5), // Tomorrow.
      ],
      signals: [...synthSignals(30), DailySignals(day: d(1))].reversed.toList(),
      tz: 'Europe/Warsaw',
      today: today,
    );
    expect(input.checkins.map((c) => c.day), [d(3), d(0)]);
    expect(input.signals, hasLength(21));
    expect(input.signals.first.day, d(20));
    expect(input.signals.last.day, d(0));
    expect(input.signals.any((s) => s.isEmpty), isFalse);
  });

  test('toJson is {checkins, signals, tz} with the agreed keys', () {
    final j = AnalysisInput.window(
      checkins: [CheckIn(day: d(0), mood: 4, energy: 3, sleep: 5)],
      signals: [DailySignals(day: d(0), sleepMinutes: 420, steps: 8000, restingHr: 55)],
      tz: 'Europe/Warsaw',
      today: today,
    ).toJson();
    expect(j, {
      'checkins': [
        {'day': '2026-10-25', 'mood': 4, 'energy': 3, 'sleep': 5},
      ],
      'signals': [
        {'day': '2026-10-25', 'sleep_minutes': 420, 'steps': 8000, 'resting_hr': 55},
      ],
      'tz': 'Europe/Warsaw',
    });
  });

  test('collect reads Health Connect only when granted; a failed read keeps check-ins', () async {
    final store = InMemoryStateStore();
    final checkIns = CheckInStore(store, clock: () => today);
    await checkIns.save(CheckIn(day: d(1), mood: 3, energy: 3, sleep: 3));
    final health = FakeHealthPort(days: synthSignals(21), tz: 'Europe/Warsaw');

    var input = await collectAnalysisInput(checkIns: checkIns, health: health, today: today, fallbackTz: 'UTC');
    expect(health.readCalls, isEmpty);
    expect((input.signals.length, input.checkins.length, input.tz), (0, 1, 'UTC'));

    health.granted = true;
    input = await collectAnalysisInput(checkIns: checkIns, health: health, today: today);
    expect(health.readCalls.single, 21);
    expect((input.signals.length, input.tz), (21, 'Europe/Warsaw'));

    final logs = <String>[];
    health.readError = const HealthException('read_failed');
    input = await collectAnalysisInput(checkIns: checkIns, health: health, today: today, log: logs.add);
    expect((input.signals.length, input.checkins.length), (0, 1));
    expect(logs, ['health: read_failed code=read_failed']);
  });
}
