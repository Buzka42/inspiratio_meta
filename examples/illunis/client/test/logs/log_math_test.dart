// Totals, volume, pace, splits and averages are plain code (build plan B6).
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_math.dart';

import 'log_fixtures.dart';

void main() {
  group('entries', () {
    test('round-trip through the server envelope', () {
      for (final e in <LogEntry>[food, walk, strength, run, rowing]) {
        final back = LogEntry.fromJson(e.toJson());
        expect(back, isNotNull, reason: e.kind.wire);
        expect(back!.toJson(), e.toJson());
      }
    });

    test('reads the shapes server/src/logs/schemas.js returns', () {
      final s = LogEntry.fromJson(envelope('strength', {
        'exercises': [
          {
            'name': 'bench',
            'sets': [
              {'reps': 10, 'weight': 60, 'unit': 'kg'},
              {'reps': 12, 'weight': null, 'unit': null},
            ],
          },
        ],
      }));
      expect(s, isA<StrengthEntry>());
      expect((s as StrengthEntry).exercises.single.sets.last.weight, isNull);
      final r = LogEntry.fromJson(envelope('run', {
        'distance': {'value': 5, 'unit': 'km'},
        'duration_s': 1500,
        'splits': [
          {'index': 1, 'distance': null, 'duration_s': 300},
        ],
      }));
      expect((r as RunEntry).splits.single.distance, isNull);
    });

    test('rejects bad envelopes and fields', () {
      expect(LogEntry.fromJson(null), isNull);
      expect(LogEntry.fromJson({...envelope('food', {'items': []})}), isNull);
      expect(LogEntry.fromJson(envelope('food', {'items': [{'name': 'x', 'unit': 'cup'}]})), isNull);
      expect(LogEntry.fromJson(envelope('run', {'distance': {'value': 5, 'unit': 'm'}, 'duration_s': 1})), isNull);
      expect(LogEntry.fromJson({...envelope('cardio', {'type': 'row'}), 'schema': 'other'}), isNull);
      expect(LogEntry.fromJson(envelope('cardio', {'type': 'row'}, date: '2026-13-01')), isNull);
      expect(LogEntry.fromJson(envelope('sleep', {'type': 'x'})), isNull);
      // A weight needs a unit.
      expect(
          LogEntry.fromJson(envelope('strength', {
            'exercises': [
              {'name': 'b', 'sets': [{'reps': 1, 'weight': 5}]},
            ],
          })),
          isNull);
    });
  });

  test('food totals count kcal only where stated', () {
    final t = foodTotals([food, lunch]);
    expect(t.kcal, 550.5);
    expect(t.stated, 2);
    expect(t.items, 3);
    final none = foodTotals([const FoodEntry(date: day, items: [FoodItem(name: 'tea')])]);
    expect(none.kcal, 0);
    expect(none.stated, 0);
  });

  test('activity totals: duration, distance per unit (m folded into km), steps', () {
    final t = activityTotals([walk, swim, const ActivityEntry(date: day, type: 'hike', distance: Distance(2, 'mi'))]);
    expect(t.durationS, 4200);
    expect(t.distance['km'], closeTo(4.0, 1e-9));
    expect(t.distance['mi'], 2);
    expect(t.steps, 4100);
  });

  group('strength volume', () {
    test('per set, per exercise and per session', () {
      expect(setVolume(squat.sets.first), 500);
      expect(setVolume(pullup.sets.first), isNull);
      expect(exerciseVolume(squat), {'kg': 1500});
      expect(exerciseVolume(pullup), isEmpty);
      expect(sessionVolume([strength]), {'kg': 1500});
      expect(totalReps([strength]), 29);
      expect(totalSets([strength]), 5);
    });

    test('kg and lb are kept apart', () {
      const mixed = StrengthEntry(date: day, exercises: [
        Exercise(name: 'curl', sets: [StrengthSet(reps: 10, weight: 25, unit: 'lb')]),
      ]);
      expect(sessionVolume([strength, mixed]), {'kg': 1500, 'lb': 250});
    });
  });

  group('run', () {
    test('pace per km and per mile', () {
      expect(runPace(run), 312);
      expect(paceText(runPace(run)!, 'km'), '5:12/km');
      const mile = RunEntry(date: day, distance: Distance(3, 'mi'), durationS: 1620);
      expect(paceText(runPace(mile)!, 'mi'), '9:00/mi');
      expect(pace(100, 0), isNull);
    });

    test('split table: elapsed time, pace only where distance was stated', () {
      final rows = splitRows(run);
      expect(rows.map((r) => r.elapsedS), [310, 630, 945]);
      expect(rows.map((r) => r.paceS), [310, 320, null]);
      expect(clock(rows.last.elapsedS), '15:45');
    });

    test('a day of runs averages pace only within one unit', () {
      const second = RunEntry(date: day, distance: Distance(3, 'km'), durationS: 960);
      final t = runTotals([run, second]);
      expect(t.distance, {'km': 8});
      expect(t.durationS, 2520);
      expect(t.paceS, 315);
      const mile = RunEntry(date: day, distance: Distance(1, 'mi'), durationS: 500);
      expect(runTotals([run, mile]).paceS, isNull);
    });
  });

  group('cardio', () {
    test('duration-weighted average, top HR, kcal only when logged', () {
      final t = cardioTotals([rowing, bike]);
      expect(t.durationS, 2400);
      expect(t.hrAvg, closeTo((140 * 1800 + 120 * 600) / 2400, 1e-9));
      expect(t.hrMax, 165);
      expect(t.kcal, 90);
      expect(cardioTotals([rowing]).kcal, isNull);
    });

    test('plain mean when a session has no duration', () {
      final t = cardioTotals([rowing, const CardioEntry(date: day, type: 'x', hrAvg: 100)]);
      expect(t.hrAvg, 120);
      expect(cardioTotals([const CardioEntry(date: day, type: 'x')]).hrAvg, isNull);
    });
  });

  test('wellbeing: last 7 days with gaps, and averages over days with data', () {
    final days = lastDays([
      const DailySignals(day: '2026-10-28', sleepMinutes: 420, steps: 8000, restingHr: 54),
      const DailySignals(day: '2026-10-25', sleepMinutes: 480, steps: 6000),
      const DailySignals(day: '2026-10-10', sleepMinutes: 1),
    ], DateTime(2026, 10, 28, 9));
    expect(days.map((d) => d.day).first, '2026-10-22');
    expect(days.map((d) => d.day).last, '2026-10-28');
    expect(days.where((d) => !d.isEmpty).length, 2);
    final a = signalAverages(days);
    expect(a.sleepMinutes, 450);
    expect(a.steps, 7000);
    expect(a.restingHr, 54);
  });

  test('formatting', () {
    expect(clock(3903), '1:05:03');
    expect(hoursMinutes(4800), '1 h 20 min');
    expect(hoursMinutes(2700), '45 min');
    expect(hoursMinutes(30), '30 s');
    expect(numText(4800), '4,800');
    expect(numText(3.25, digits: 2), '3.25');
    expect(numText(3.20, digits: 2), '3.2');
    expect(volumeText({'kg': 1500, 'lb': 250}), '1,500 kg · 250 lb');
  });
}
