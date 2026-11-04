// Audit of every log view at phone width (360 px) with the real fonts:
// empty, one-entry and long-data states, totals checked by hand against
// log_math.dart, dates, units, no overflow and no clipped text, and the
// keyboard or a large text size never pushing the view off screen.
// Synthetic data only.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/view_requests.dart';
import 'package:illunis_client/breath/breath_view.dart';
import 'package:illunis_client/breath/breath_wiring.dart';
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_math.dart';
import 'package:illunis_client/logs/log_store.dart';
import 'package:illunis_client/logs/views/log_frame.dart';
import 'package:illunis_client/logs/views/log_views.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';

import '../app/view_audit_helpers.dart';
import '../breath/breath_fixtures.dart';
import 'log_fixtures.dart' as fx;

const day = fx.day; // Wednesday 28 October 2026

// ---- food ------------------------------------------------------------------
// 7 items, 5 with kcal: 300 + 612 + 195 + 230.5 + 52 = 1,389.5 kcal.
const longFood = [
  FoodEntry(date: day, meal: 'breakfast', items: [
    FoodItem(name: 'porridge', quantity: 80, unit: 'g', kcal: 300),
    FoodItem(name: 'coffee'),
  ]),
  FoodEntry(date: day, meal: 'lunch', items: [
    FoodItem(
        name: 'roasted sweet potato, chickpea and spinach salad with tahini and lemon dressing',
        quantity: 1,
        unit: 'serving',
        kcal: 612),
  ]),
  FoodEntry(date: day, meal: 'dinner', items: [
    FoodItem(name: 'rice', quantity: 150, unit: 'g', kcal: 195),
    FoodItem(name: 'dal', quantity: 200, unit: 'g', kcal: 230.5),
    FoodItem(name: 'yoghurt', quantity: 125, unit: 'ml'),
  ]),
  FoodEntry(date: day, meal: 'snack', items: [FoodItem(name: 'apple', quantity: 1, unit: 'piece', kcal: 52)]),
];
const oneFood = FoodEntry(date: day, items: [FoodItem(name: 'banana')]);

// ---- activity --------------------------------------------------------------
// Time 3,585 + 3,585 = 7,170 s = 119.5 min, which rounds to 2 h.
// Distance 3.2 km + 800 m (0.8 km) = 4 km, and 2 mi kept apart. Steps 4,100.
const longActivity = [
  ActivityEntry(date: day, type: 'walk', durationS: 3585, distance: Distance(3.2, 'km'), steps: 4100),
  ActivityEntry(date: day, type: 'cycle', durationS: 3585, distance: Distance(2, 'mi')),
  ActivityEntry(date: day, type: 'gardening'),
  ActivityEntry(date: day, type: 'swim', distance: Distance(800, 'm')),
];
const oneActivity = ActivityEntry(date: day, type: 'walk', steps: 12000);

// ---- strength --------------------------------------------------------------
// squat 3 x 5 x 100 kg = 1,500 kg; RDL 3 x 8 x 62.5 kg = 1,500 kg;
// bench 3 x 8 x 135 lb = 3,240 lb; pull-up bodyweight; row 4 x 10 x 22.5 kg
// = 900 kg. kg 3,900, lb 3,240. Sets 3+3+3+3+4 = 16. Reps 15+24+24+24+40 = 127.
const longStrength = StrengthEntry(date: day, exercises: [
  Exercise(name: 'squat', sets: [
    StrengthSet(reps: 5, weight: 100, unit: 'kg'),
    StrengthSet(reps: 5, weight: 100, unit: 'kg'),
    StrengthSet(reps: 5, weight: 100, unit: 'kg'),
  ]),
  Exercise(name: 'romanian deadlift with a pause just below the knee', sets: [
    StrengthSet(reps: 8, weight: 62.5, unit: 'kg'),
    StrengthSet(reps: 8, weight: 62.5, unit: 'kg'),
    StrengthSet(reps: 8, weight: 62.5, unit: 'kg', effort: Effort('rpe', 8.5)),
  ]),
  Exercise(name: 'bench press', sets: [
    StrengthSet(reps: 8, weight: 135, unit: 'lb'),
    StrengthSet(reps: 8, weight: 135, unit: 'lb'),
    StrengthSet(reps: 8, weight: 135, unit: 'lb'),
  ]),
  Exercise(name: 'pull-up', sets: [StrengthSet(reps: 8), StrengthSet(reps: 8), StrengthSet(reps: 8)]),
  Exercise(name: 'dumbbell row', sets: [
    StrengthSet(reps: 10, weight: 22.5, unit: 'kg'),
    StrengthSet(reps: 10, weight: 22.5, unit: 'kg'),
    StrengthSet(reps: 10, weight: 22.5, unit: 'kg'),
    StrengthSet(reps: 10, weight: 22.5, unit: 'kg'),
  ]),
]);
const oneStrength = StrengthEntry(date: day, exercises: [
  Exercise(name: 'push-up', sets: [StrengthSet(reps: 12)]),
]);

// ---- run -------------------------------------------------------------------
// Half marathon: 21 splits of 1 km in 300 s, then 0.1 km in 30 s:
// 21 x 300 + 30 = 6,330 s = 1:45:30; pace 6,330 / 21.1 = 300 s = 5:00/km.
// Second run 3 mi in 1,500 s: 500 s/mi = 8:20/mi. Day 6,330 + 1,500 = 7,830 s
// = 2:10:30, no average pace across km and mi.
final halfMarathon = RunEntry(date: day, distance: const Distance(21.1, 'km'), durationS: 6330, splits: [
  for (var i = 1; i <= 21; i++) RunSplit(index: i, distance: 1, durationS: 300),
  const RunSplit(index: 22, distance: 0.1, durationS: 30),
]);
const milesRun = RunEntry(date: day, distance: Distance(3, 'mi'), durationS: 1500);
const oneRun = RunEntry(date: day, distance: Distance(5, 'km'), durationS: 1560);

// ---- cardio ----------------------------------------------------------------
// The stair climber has no duration, so the average is a plain mean:
// (140 + 120 + 130 + 150) / 4 = 135. Top 171. Time 1,800 + 600 + 2,400 =
// 4,800 s = 1 h 20 min. kcal 90 + 310.5 = 400.5.
const longCardio = [
  CardioEntry(date: day, type: 'rowing', durationS: 1800, hrAvg: 140, hrMax: 165),
  CardioEntry(date: day, type: 'bike', durationS: 600, hrAvg: 120, hrMax: 150, kcal: 90),
  CardioEntry(date: day, type: 'elliptical', durationS: 2400, hrAvg: 130, hrMax: 158, kcal: 310.5),
  CardioEntry(date: day, type: 'stair climber', hrAvg: 150, hrMax: 171),
];
const oneCardio = CardioEntry(date: day, type: 'yoga');

// ---- wellbeing -------------------------------------------------------------
// Sleep (420+480+455+390+510+445+465) / 7 = 3,165 / 7 = 452.1 min = 7 h 32 min.
// Steps (8,000+6,000+12,345+3,000+9,500+7,000+10,000) / 7 = 55,845 / 7 = 7,977.9
// = 7,978. Resting HR (54+55+53+56+52+54+55) / 7 = 379 / 7 = 54.1 = 54.
const longSignals = [
  DailySignals(day: '2026-10-22', sleepMinutes: 420, steps: 8000, restingHr: 54),
  DailySignals(day: '2026-10-23', sleepMinutes: 480, steps: 6000, restingHr: 55),
  DailySignals(day: '2026-10-24', sleepMinutes: 455, steps: 12345, restingHr: 53),
  DailySignals(day: '2026-10-25', sleepMinutes: 390, steps: 3000, restingHr: 56),
  DailySignals(day: '2026-10-26', sleepMinutes: 510, steps: 9500, restingHr: 52),
  DailySignals(day: '2026-10-27', sleepMinutes: 445, steps: 7000, restingHr: 54),
  DailySignals(day: '2026-10-28', sleepMinutes: 465, steps: 10000, restingHr: 55),
  // Outside the 7 days: ignored.
  DailySignals(day: '2026-10-21', sleepMinutes: 60, steps: 1, restingHr: 99),
];

DateTime now = DateTime(2026, 10, 28, 9);

Future<LogViews> deps(WidgetTester t, {List<LogEntry> entries = const [], List<DailySignals>? signals,
    FakeServerPort? server}) async {
  final store = LogStore(InMemoryStateStore());
  await t.runAsync(() async {
    for (final e in entries) {
      await store.add(e);
    }
  });
  return LogViews(
    store: store,
    server: server ?? FakeServerPort(),
    signals: signals == null ? null : () async => signals,
    clock: () => now,
    log: (_) {},
  );
}

var closed = 0;

Future<void> pumpView(WidgetTester t, ViewKind kind, LogViews d,
    {Size size = phone, double textScale = 1, double keyboard = 0, bool day = false}) async {
  phoneSurface(t, size: size);
  final view = logViewFor(ViewRequest(kind, kind.label), d, () => closed++)!;
  await t.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        disableAnimations: true,
        textScaler: TextScaler.linear(textScale),
        viewInsets: EdgeInsets.only(bottom: keyboard),
      ),
      child: day ? SkyLight(daylight: 1, palette: Palette.day, child: view) : view,
    ),
  ));
  await t.pumpAndSettle();
}

/// Scrolls the view's list until [f] is built and on screen.
Future<void> reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isNotEmpty) return;
  await t.scrollUntilVisible(f, 200,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
}

/// The total's plain text (it is drawn as a figure row of spans).
Future<String> totalText(WidgetTester t) async {
  await reveal(t, find.byKey(LogKeys.total));
  final text = t.widget<Text>(find.descendant(of: find.byKey(LogKeys.total), matching: find.byType(Text)));
  return text.textSpan?.toPlainText() ?? text.data!;
}

/// The value beside [label] in a LogRow.
Future<String> rowValue(WidgetTester t, String label) async {
  await reveal(t, find.text(label));
  final row = find.ancestor(of: find.text(label), matching: find.byType(LogRow)).first;
  return t.widget<LogRow>(row).value;
}

void main() {
  setUpAll(loadCaptionFonts);
  setUp(() => now = DateTime(2026, 10, 28, 9));

  group('number formatting (log_math)', () {
    test('a whole number of minutes never shows 60 min', () {
      expect(hoursMinutes(3585), '1 h'); // 59.75 min
      expect(hoursMinutes(7170), '2 h'); // 119.5 min
      expect(hoursMinutes(3570), '1 h'); // 59.5 min
      expect(hoursMinutes(5370), '1 h 30 min'); // 89.5 min rounds up
      expect(hoursMinutes(59.6), '1 min');
      expect(hoursMinutes(45), '45 s');
      expect(hoursMinutes(2400), '40 min');
    });

    test('thousands are grouped with or without decimals', () {
      expect(numText(1389.5), '1,389.5');
      expect(numText(12345.25, digits: 2), '12,345.25');
      expect(numText(-1234.5), '-1,234.5');
      expect(numText(1500), '1,500');
      expect(numText(0.1, digits: 2), '0.1');
      expect(numText(21.1, digits: 2), '21.1');
    });
  });

  group('food', () {
    testWidgets('empty state fits and says what to type', (t) async {
      await pumpView(t, ViewKind.food, await deps(t));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expect(find.textContaining('porridge 80 g'), findsWidgets);
      expectFits(t);
    });

    testWidgets('one item without calories', (t) async {
      await pumpView(t, ViewKind.food, await deps(t, entries: [oneFood]));
      expect(find.text('banana'), findsOneWidget);
      expect(await totalText(t), '1 item · no calories stated');
      expectFits(t);
    });

    testWidgets('a long day: meals, units, kcal only where stated, grouped total', (t) async {
      await pumpView(t, ViewKind.food, await deps(t, entries: longFood));
      for (final m in ['Breakfast', 'Lunch', 'Dinner', 'Snack']) {
        expect(find.text(m), findsOneWidget, reason: m);
      }
      expect(await rowValue(t, 'rice'), '150 g · 195 kcal');
      expect(await rowValue(t, 'dal'), '200 g · 230.5 kcal');
      expect(await rowValue(t, 'yoghurt'), '125 ml');
      expect(await rowValue(t, 'apple'), '1 piece · 52 kcal');
      expect(await rowValue(t, longFood[1].items.single.name), '1 serving · 612 kcal');
      expect(await totalText(t), '7 items · 1,389.5 kcal stated for 5 of 7');
      expectFits(t);
    });
  });

  group('activity', () {
    testWidgets('empty state fits', (t) async {
      await pumpView(t, ViewKind.activity, await deps(t));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expectFits(t);
    });

    testWidgets('one activity with steps only', (t) async {
      await pumpView(t, ViewKind.activity, await deps(t, entries: [oneActivity]));
      expect(await rowValue(t, 'Walk'), '12,000 steps');
      expect(await totalText(t), '1 activity · 12,000 steps');
      expectFits(t);
    });

    testWidgets('a long day: minutes round to whole hours, metres fold into km, miles kept', (t) async {
      await pumpView(t, ViewKind.activity, await deps(t, entries: longActivity));
      expect(await rowValue(t, 'Walk'), '1 h · 3.2 km · 4,100 steps');
      expect(await rowValue(t, 'Cycle'), '1 h · 2 mi');
      expect(await rowValue(t, 'Swim'), '800 m');
      expect(find.text('Gardening'), findsOneWidget);
      expect(await totalText(t), '4 activities · 2 h · 4 km · 2 mi · 4,100 steps');
      expectFits(t);
    });
  });

  group('strength', () {
    testWidgets('empty state fits', (t) async {
      await pumpView(t, ViewKind.strength, await deps(t));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expectFits(t);
    });

    testWidgets('one bodyweight set: no volume', (t) async {
      await pumpView(t, ViewKind.strength, await deps(t, entries: [oneStrength]));
      expect(find.text('Push-up'), findsOneWidget);
      expect(find.text('Set 1: 12 × bodyweight'), findsOneWidget);
      expect(await totalText(t), '1 set · 12 reps');
      expectFits(t);
    });

    testWidgets('a long session: kg and lb kept apart, decimals, RPE only where logged', (t) async {
      await pumpView(t, ViewKind.strength, await deps(t, entries: [longStrength]));
      expect(find.text('1,500 kg'), findsNWidgets(2)); // squat and RDL
      expect(find.text('Set 1: 8 × 62.5 kg'), findsOneWidget);
      expect(find.text('Set 3: 8 × 62.5 kg · RPE 8.5'), findsOneWidget);
      expectFits(t);
      await reveal(t, find.text('3,240 lb'));
      await reveal(t, find.text('900 kg'));
      await reveal(t, find.text('Set 4: 10 × 22.5 kg'));
      expect(find.textContaining('RIR'), findsNothing);
      expect(await totalText(t), '16 sets · 127 reps · volume 3,900 kg · 3,240 lb');
      expectFits(t);
    });
  });

  group('run', () {
    testWidgets('empty state fits', (t) async {
      await pumpView(t, ViewKind.run, await deps(t));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expectFits(t);
    });

    testWidgets('one run without splits: no table', (t) async {
      await pumpView(t, ViewKind.run, await deps(t, entries: [oneRun]));
      expect(await rowValue(t, 'Run 1'), '5 km · 26:00 · 5:12/km');
      expect(find.byType(Table), findsNothing);
      expect(await totalText(t), '1 run · 5 km · 26:00 · average 5:12/km');
      expectFits(t);
    });

    testWidgets('a half marathon with 22 splits and a run in miles', (t) async {
      await pumpView(t, ViewKind.run, await deps(t, entries: [halfMarathon, milesRun]));
      expect(await rowValue(t, 'Run 1'), '21.1 km · 1:45:30 · 5:00/km');
      expect(await rowValue(t, 'Run 2'), '3 mi · 25:00 · 8:20/mi');
      await reveal(t, find.text('1:00:00')); // elapsed after split 12
      await reveal(t, find.text('1:45:30')); // elapsed after split 22
      expect(find.text('0.1'), findsOneWidget);
      expect(await totalText(t), '2 runs · 21.1 km · 3 mi · 2:10:30');
      expectFits(t);
    });
  });

  group('cardio', () {
    testWidgets('empty state fits', (t) async {
      await pumpView(t, ViewKind.cardio, await deps(t));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expectFits(t);
    });

    testWidgets('one session with only its type', (t) async {
      await pumpView(t, ViewKind.cardio, await deps(t, entries: [oneCardio]));
      expect(find.text('Yoga'), findsOneWidget);
      expect(await totalText(t), '1 session');
      expectFits(t);
    });

    testWidgets('a long day: plain mean HR when a session has no time, kcal summed', (t) async {
      await pumpView(t, ViewKind.cardio, await deps(t, entries: longCardio));
      expect(await rowValue(t, 'Elliptical'), '40 min · avg 130 bpm · top 158 bpm · 310.5 kcal');
      expect(await rowValue(t, 'Stair climber'), 'avg 150 bpm · top 171 bpm');
      expect(await totalText(t), '4 sessions · 1 h 20 min · avg 135 bpm · top 171 bpm · 400.5 kcal');
      expectFits(t);
    });
  });

  group('wellbeing', () {
    testWidgets('no device signals: empty state fits', (t) async {
      await pumpView(t, ViewKind.wellbeing, await deps(t, signals: const []));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expect(find.text('Last 7 days, 22 Oct to 28 Oct'), findsOneWidget);
      expectFits(t);
    });

    testWidgets('one day of signals: the other six show a dash', (t) async {
      await pumpView(t, ViewKind.wellbeing,
          await deps(t, signals: const [DailySignals(day: '2026-10-28', sleepMinutes: 455)]));
      expect(find.text('7 h 35 min'), findsOneWidget); // 455 min
      expect(find.text('–'), findsNWidgets(6 * 3 + 2)); // 6 empty days, plus steps and HR today
      expect(await totalText(t), '7-day average · sleep 7 h 35 min');
      expectFits(t);
    });

    testWidgets('seven full days: averages by hand, older days ignored', (t) async {
      await pumpView(t, ViewKind.wellbeing, await deps(t, signals: longSignals));
      expect(find.text('21 Oct'), findsNothing);
      expect(find.text('12,345'), findsOneWidget);
      expect(find.text('8 h 30 min'), findsOneWidget); // 510 min
      expect(await totalText(t), '7-day average · sleep 7 h 32 min · 7,978 steps · resting HR 54 bpm');
      expectFits(t);
    });

    testWidgets('the week crosses a month boundary', (t) async {
      now = DateTime(2026, 11, 3, 7);
      await pumpView(t, ViewKind.wellbeing,
          await deps(t, signals: const [DailySignals(day: '2026-10-28', steps: 4321)]));
      expect(find.text('Last 7 days, 28 Oct to 3 Nov'), findsOneWidget);
      expect(find.text('4,321'), findsOneWidget);
      expectFits(t);
    });
  });

  group('overview (show my logs)', () {
    testWidgets('empty state fits', (t) async {
      await pumpView(t, ViewKind.logs, await deps(t));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      expect(find.text('Today, Wednesday 28 October'), findsOneWidget);
      expectFits(t);
    });

    testWidgets('one entry: singular count', (t) async {
      await pumpView(t, ViewKind.logs, await deps(t, entries: [oneRun]));
      expect(await rowValue(t, 'Runs'), '1 run · 5 km · 26:00 · average 5:12/km');
      expect(find.text('Nothing logged'), findsNWidgets(4));
      expect(await totalText(t), '1 entry today');
      expectFits(t);
    });

    testWidgets('every kind filled: each total matches its own view', (t) async {
      final entries = <LogEntry>[...longFood, ...longActivity, longStrength, halfMarathon, milesRun, ...longCardio];
      await pumpView(t, ViewKind.logs, await deps(t, entries: entries));
      expect(await rowValue(t, 'Food'), '7 items · 1,389.5 kcal stated for 5 of 7');
      expect(await rowValue(t, 'Activity'), '4 activities · 2 h · 4 km · 2 mi · 4,100 steps');
      expect(await rowValue(t, 'Strength'), '16 sets · 127 reps · volume 3,900 kg · 3,240 lb');
      expect(await rowValue(t, 'Runs'), '2 runs · 21.1 km · 3 mi · 2:10:30');
      expect(await rowValue(t, 'Cardio'), '4 sessions · 1 h 20 min · avg 135 bpm · top 171 bpm · 400.5 kcal');
      expect(find.text('Nothing logged'), findsNothing);
      expect(await totalText(t), '15 entries today'); // 4 + 4 + 1 + 2 + 4
      expectFits(t);
    });

    testWidgets('only today: an entry from yesterday is not counted', (t) async {
      const yesterday = RunEntry(date: '2026-10-27', distance: Distance(5, 'km'), durationS: 1560);
      await pumpView(t, ViewKind.logs, await deps(t, entries: [yesterday]));
      expect(find.byKey(LogKeys.empty), findsOneWidget);
    });
  });

  group('dates', () {
    testWidgets('previous day across a month boundary shows that day\'s entries', (t) async {
      now = DateTime(2026, 11, 1, 8);
      const halloween = FoodEntry(date: '2026-10-31', items: [FoodItem(name: 'pumpkin soup', kcal: 180)]);
      await pumpView(t, ViewKind.food, await deps(t, entries: [halloween]));
      expect(find.text('Today, Sunday 1 November'), findsOneWidget);
      expect(find.byKey(LogKeys.empty), findsOneWidget);
      await t.tap(find.byKey(LogKeys.prevDay));
      await t.pumpAndSettle();
      expect(find.text('Saturday 31 October'), findsOneWidget);
      expect(await totalText(t), '1 item · 180 kcal stated for 1 of 1');
      expectFits(t);
    });
  });

  group('layout under pressure', () {
    for (final scale in [1.5, 2.0]) {
      for (final kind in [ViewKind.food, ViewKind.activity, ViewKind.strength, ViewKind.run, ViewKind.cardio, ViewKind.logs]) {
        testWidgets('${kind.name}: ${scale}x text at 360 px fits', (t) async {
          final entries = <LogEntry>[...longFood, ...longActivity, longStrength, halfMarathon, ...longCardio];
          await pumpView(t, kind, await deps(t, entries: entries), textScale: scale);
          expectFits(t, reason: kind.name);
        });
      }
      testWidgets('empty states: ${scale}x text at 360 px fit', (t) async {
        for (final kind in ViewKind.values.where((k) => k != ViewKind.breathwork)) {
          await pumpView(t, kind, await deps(t, signals: const []), textScale: scale);
          expect(find.byKey(LogKeys.empty), findsOneWidget, reason: kind.name);
          expectFits(t, reason: kind.name);
        }
      });
    }

    testWidgets('wellbeing: 1.5x text at 360 px fits, one line per day when the table cannot', (t) async {
      await pumpView(t, ViewKind.wellbeing, await deps(t, signals: longSignals), textScale: 1.5);
      expectFits(t);
      expect(find.byType(Table), findsNothing);
      expect(await rowValue(t, '24 Oct'), 'sleep 7 h 35 min · 12,345 steps · resting HR 53 bpm');
    });

    // Body text has no tracking since UI-0, so the five columns still fit
    // at 2x; at 2.5x they do not and each split becomes one line.
    testWidgets('run: 1.5x text keeps a table that fits; at 2.5x each split is one line', (t) async {
      await pumpView(t, ViewKind.run, await deps(t, entries: [halfMarathon]), textScale: 1.5);
      expect(find.byType(Table), findsOneWidget);
      expectFits(t);
      await pumpView(t, ViewKind.run, await deps(t, entries: [halfMarathon]), textScale: 2.5);
      expect(find.byType(Table), findsNothing);
      expect(await rowValue(t, 'Split 1'), '1 km · 5:00 · elapsed 5:00 · 5:00/km');
      expect(await rowValue(t, 'Split 12'), '1 km · 5:00 · elapsed 1:00:00 · 5:00/km');
      expect(await rowValue(t, 'Split 22'), '0.1 km · 0:30 · elapsed 1:45:30 · 5:00/km');
      expectFits(t);
    });

    testWidgets('run: at 1x text the split table keeps its columns', (t) async {
      await pumpView(t, ViewKind.run, await deps(t, entries: [halfMarathon]));
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('Elapsed'), findsOneWidget);
    });

    testWidgets('a long preview with the keyboard up fits a small phone', (t) async {
      final server = FakeServerPort()
        ..logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(longStrength.toJson()));
      await pumpView(t, ViewKind.strength, await deps(t, server: server), size: const Size(360, 640), keyboard: 280);
      await t.enterText(find.byKey(LogKeys.field), 'squat 3x5 at 100 kg and more');
      await t.tap(find.byKey(LogKeys.send));
      await t.pumpAndSettle();
      expect(find.text('Save?'), findsOneWidget);
      expectFits(t);
      // Yes, No and the field stay on screen above the keyboard.
      for (final k in [LogKeys.saveYes, LogKeys.saveNo, LogKeys.field]) {
        expect(t.getRect(find.byKey(k)).bottom, lessThanOrEqualTo(640 - 280), reason: '$k');
      }
    });

    testWidgets('food choice rows with the keyboard up fit a small phone', (t) async {
      final server = FakeServerPort()
        ..cannedLogChoice(Map<String, dynamic>.from(fx.pendingFood), [fx.porridgeChoice, fx.coffeeChoice]);
      await pumpView(t, ViewKind.food, await deps(t, server: server), size: const Size(360, 640), keyboard: 280);
      await t.enterText(find.byKey(LogKeys.field), 'porridge 80 g and a coffee');
      await t.tap(find.byKey(LogKeys.send));
      await t.pumpAndSettle();
      expect(find.byKey(LogKeys.choiceDiscard), findsOneWidget);
      expectFits(t);
      expect(t.getRect(find.byKey(LogKeys.field)).bottom, lessThanOrEqualTo(640 - 280));
    });
  });

  group('one glass sheet', () {
    final all = <LogEntry>[...longFood, ...longActivity, longStrength, halfMarathon, ...longCardio];
    final kinds = ViewKind.values.where((k) => k != ViewKind.breathwork);

    testWidgets('no stock Material controls: no TextButton, IconButton, Divider or Icon', (t) async {
      for (final kind in kinds) {
        await pumpView(t, kind, await deps(t, entries: all, signals: longSignals));
        for (final type in [TextButton, IconButton, Divider, Icon]) {
          expect(find.byType(type), findsNothing, reason: '${kind.name}: $type');
        }
      }
    });

    testWidgets('every tappable is at least 48 x 48', (t) async {
      for (final kind in kinds) {
        await pumpView(t, kind, await deps(t, entries: all, signals: longSignals));
        for (final e in find.byType(InkWell).evaluate()) {
          if ((e.widget as InkWell).onTap == null) continue;
          final size = (e.renderObject! as RenderBox).size;
          expect(size.width, greaterThanOrEqualTo(48), reason: '${kind.name} ${e.widget.key}');
          expect(size.height, greaterThanOrEqualTo(48), reason: '${kind.name} ${e.widget.key}');
        }
      }
    });

    testWidgets('every table cell has tabular figures', (t) async {
      for (final kind in [ViewKind.run, ViewKind.wellbeing]) {
        await pumpView(t, kind, await deps(t, entries: [halfMarathon], signals: longSignals));
        final cells = find.descendant(of: find.byType(Table), matching: find.byType(Text));
        expect(cells, findsWidgets, reason: kind.name);
        for (final c in t.widgetList<Text>(cells)) {
          expect(c.style!.fontFeatures, contains(const FontFeature.tabularFigures()), reason: '${kind.name} "${c.data}"');
        }
      }
    });

    testWidgets('the total is a figure row: numbers in the reply serif, the words small', (t) async {
      await pumpView(t, ViewKind.food, await deps(t, entries: longFood));
      await reveal(t, find.byKey(LogKeys.total));
      final text = t.widget<Text>(find.descendant(of: find.byKey(LogKeys.total), matching: find.byType(Text)));
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      final figures = [for (final s in spans) if (s.style != null) s.text];
      expect(figures, ['7', '1,389.5', '5', '7']);
      expect(spans.firstWhere((s) => s.style != null).style!.fontFamily, Fonts.serif);
      expect(text.style!.fontFamily, Fonts.sans);
    });

    testWidgets('by day the sheet takes the day halo, its text inverse-colour', (t) async {
      await pumpView(t, ViewKind.food, await deps(t, entries: longFood), day: true);
      for (final s in ['Food', 'rice', '150 g · 195 kcal']) {
        final style = t.renderObject<RenderParagraph>(find.text(s)).text.style!;
        expect(TypeScale.isInverse(style), isTrue, reason: s);
        expect(style.shadows!.first.color.withValues(alpha: 1), Palette.day.halo.withValues(alpha: 1), reason: s);
      }
      await pumpView(t, ViewKind.food, await deps(t, entries: longFood));
      expect(TypeScale.isInverse(t.widget<Text>(find.text('Food')).style), isTrue);
    });

    testWidgets('row values end at the right edge in tabular figures, so digits line up', (t) async {
      for (final (kind, entries) in [
        (ViewKind.food, longFood),
        (ViewKind.cardio, longCardio),
        (ViewKind.logs, <LogEntry>[...longFood, halfMarathon]),
      ]) {
        await pumpView(t, kind, await deps(t, entries: entries));
        final rows = t.widgetList<LogRow>(find.byType(LogRow)).toList();
        expect(rows, isNotEmpty, reason: kind.name);
        for (final r in rows) {
          if (r.value.isEmpty) continue;
          final v = t.widget<Text>(find.descendant(of: find.byWidget(r), matching: find.text(r.value)));
          expect(v.style!.fontFeatures, contains(const FontFeature.tabularFigures()), reason: '${kind.name} ${r.value}');
          expect(v.textAlign, TextAlign.end, reason: '${kind.name} ${r.value}');
        }
      }
    });

    testWidgets('headings share one face and one space above, in every view', (t) async {
      final styles = <String, TextStyle>{};
      final tops = <String, double>{};
      Future<void> grab(ViewKind kind, List<LogEntry> entries, String heading) async {
        await pumpView(t, kind, await deps(t, entries: entries));
        final f = find.text(heading).first;
        styles[heading] = t.widget<Text>(f).style!;
        // The gap from the heading's padding box to its text.
        final pad = find.ancestor(of: f, matching: find.byType(Padding)).first;
        tops[heading] = t.getRect(f).top - t.getRect(pad).top;
      }

      await grab(ViewKind.food, longFood, 'Breakfast');
      await grab(ViewKind.strength, [longStrength], 'Squat');
      await grab(ViewKind.run, [oneRun], 'Run 1');
      await grab(ViewKind.logs, [oneRun], 'Runs');
      final first = styles.values.first;
      for (final MapEntry(:key, :value) in styles.entries) {
        expect(value.fontFamily, first.fontFamily, reason: key);
        expect(value.fontSize, first.fontSize, reason: key);
        expect(value.fontVariations, first.fontVariations, reason: key);
        expect(value.color, first.color, reason: key);
        expect(TypeScale.isInverse(value), TypeScale.isInverse(first), reason: key);
        expect(tops[key], logHeadingPadding.top, reason: key);
      }
    });

    testWidgets('the rule under the day sits at one height in every view', (t) async {
      double? at;
      for (final kind in kinds) {
        await pumpView(t, kind, await deps(t, signals: const []));
        final empty = t.getRect(find.byKey(LogKeys.empty)).top;
        at ??= empty;
        expect(empty, at, reason: kind.name);
      }
    });

    testWidgets('the hint is the bare example, never "e.g."', (t) async {
      await pumpView(t, ViewKind.food, await deps(t));
      final field = t.widget<TextField>(find.byKey(LogKeys.field));
      expect(field.decoration!.hintText, 'porridge 80 g and a coffee for breakfast');
      expect(find.textContaining('e.g.'), findsNothing);
    });
  });

  group('close', () {
    for (final (size, scale) in [(phone, 1.0), (phone, 2.0), (const Size(1000, 800), 1.0)]) {
      testWidgets('Close sits in one place in every view, breathwork too: '
          '${size.width.toInt()} px, ${scale}x text', (t) async {
        Rect? at;
        for (final kind in ViewKind.values.where((k) => k != ViewKind.breathwork)) {
          await pumpView(t, kind, await deps(t, signals: const []), size: size, textScale: scale);
          final r = t.getRect(find.byKey(LogKeys.close));
          at ??= r;
          expect(r, at, reason: kind.name);
        }
        expect(at!.right, closeTo(size.width - Space.s8, 0.5));
        expect(at.height, greaterThanOrEqualTo(48));
        // The breathwork view, on its first step.
        phoneSurface(t, size: size);
        await t.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size, disableAnimations: true, textScaler: TextScaler.linear(scale)),
            child: BreathView(
              request: const BreathRequest('box breathing'),
              deps: BreathDeps(library: Future.value(loadAssetLibrary()), store: InMemoryStateStore()),
              onClose: () {},
            ),
          ),
        ));
        await t.pump();
        await t.pump();
        expect(t.getRect(find.byKey(BreathView.closeKey)), at, reason: 'breathwork');
      });
    }

    for (final kind in [...ViewKind.values.where((k) => k != ViewKind.breathwork)]) {
      testWidgets('${kind.name}: Close is a 48 px target that calls back once', (t) async {
        await pumpView(t, kind, await deps(t, signals: const []));
        final size = t.getSize(find.byKey(LogKeys.close));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
        final before = closed;
        await t.tap(find.byKey(LogKeys.close));
        expect(closed, before + 1);
      });
    }
  });
}
