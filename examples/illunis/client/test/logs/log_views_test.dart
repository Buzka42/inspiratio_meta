// Each log view renders an empty state that says what to log, and its rows
// and one total line when filled, at phone width. Synthetic data.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/view_requests.dart';
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_store.dart';
import 'package:illunis_client/logs/views/log_frame.dart';
import 'package:illunis_client/logs/views/log_views.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';

import '../app/view_audit_helpers.dart';
import 'log_fixtures.dart';

final today = DateTime(2026, 10, 28, 9);

LogViews deps({List<LogEntry> entries = const [], List<DailySignals>? signals, FakeServerPort? server}) {
  final store = LogStore(InMemoryStateStore());
  for (final e in entries) {
    store.add(e);
  }
  return LogViews(
    store: store,
    server: server ?? FakeServerPort(),
    signals: signals == null ? null : () async => signals,
    clock: () => today,
    log: (_) {},
  );
}

var closed = 0;

Future<void> pumpView(WidgetTester t, ViewKind kind, LogViews d) async {
  t.view.physicalSize = const Size(360, 780);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(360, 780), disableAnimations: true),
      child: logViewFor(ViewRequest(kind, kind.label), d, () => closed++)!,
    ),
  ));
  await t.pumpAndSettle();
}

/// The total's plain text (it is drawn as a figure row of spans).
String totalText(WidgetTester t) {
  final text = t.widget<Text>(find.descendant(of: find.byKey(LogKeys.total), matching: find.byType(Text)));
  return text.textSpan?.toPlainText() ?? text.data!;
}

void main() {
  // Real caption fonts, so the split and wellbeing tables measure as on the phone.
  setUpAll(loadCaptionFonts);
  const kinds = [ViewKind.food, ViewKind.activity, ViewKind.strength, ViewKind.run, ViewKind.cardio];

  testWidgets('every log view has an empty state that says what to do, in one line', (t) async {
    final seen = <String>{};
    for (final k in [...kinds, ViewKind.wellbeing, ViewKind.logs]) {
      await pumpView(t, k, deps());
      expect(find.byKey(LogKeys.empty), findsOneWidget, reason: k.name);
      expect(find.byKey(LogKeys.total), findsNothing, reason: k.name);
      final empty = find.descendant(of: find.byKey(LogKeys.empty), matching: find.byType(Text));
      final text = t.widget<Text>(empty).data!;
      // One sentence that starts with what to do (Type, Ask, Allow).
      expect(RegExp(r'^(Type|Ask|Allow) [^.]+\.$').hasMatch(text), isTrue, reason: '${k.name}: "$text"');
      expect(seen.add(text), isTrue, reason: '${k.name}: says the same as another view');
      // One line at 360 px with the real fonts.
      final body = TypeScale.body(Palette.night.ink);
      expect(t.getSize(empty).height, lessThan(body.fontSize! * body.height! * 1.5), reason: '${k.name}: "$text"');
      expect(t.takeException(), isNull, reason: k.name);
    }
  });

  testWidgets('food: rows, kcal only where stated, total', (t) async {
    await pumpView(t, ViewKind.food, deps(entries: [food, lunch]));
    expect(find.text('Breakfast'), findsOneWidget);
    expect(find.text('porridge'), findsOneWidget);
    expect(find.text('80 g · 300 kcal'), findsOneWidget);
    expect(find.text('coffee'), findsOneWidget);
    expect(totalText(t), '3 items · 550.5 kcal stated for 2 of 3');
    expect(find.textContaining('Today, Wednesday 28 October'), findsOneWidget);
  });

  testWidgets('activity: rows and total', (t) async {
    await pumpView(t, ViewKind.activity, deps(entries: [walk, swim]));
    expect(find.text('Walk'), findsOneWidget);
    expect(find.text('40 min · 3.2 km · 4,100 steps'), findsOneWidget);
    expect(totalText(t), '2 activities · 1 h 10 min · 4 km · 4,100 steps');
  });

  testWidgets('strength: sets as reps x weight, effort only where logged, volume', (t) async {
    await pumpView(t, ViewKind.strength, deps(entries: [strength]));
    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Set 1: 5 × 100 kg'), findsOneWidget);
    expect(find.text('Set 2: 5 × 100 kg · RIR 2'), findsOneWidget);
    expect(find.text('Set 1: 8 × bodyweight'), findsOneWidget);
    expect(find.textContaining('RPE'), findsNothing);
    expect(find.text('1,500 kg'), findsOneWidget);
    expect(totalText(t), '5 sets · 29 reps · volume 1,500 kg');
  });

  testWidgets('run: distance, time, pace and split table', (t) async {
    await pumpView(t, ViewKind.run, deps(entries: [run]));
    expect(find.text('5 km · 26:00 · 5:12/km'), findsOneWidget);
    expect(find.text('Elapsed'), findsOneWidget);
    expect(find.text('10:30'), findsOneWidget); // elapsed after split 2
    expect(find.text('15:45'), findsOneWidget);
    expect(totalText(t), '1 run · 5 km · 26:00 · average 5:12/km');
  });

  testWidgets('cardio: duration, average and top HR, kcal when logged', (t) async {
    await pumpView(t, ViewKind.cardio, deps(entries: [rowing, bike]));
    expect(find.text('30 min · avg 140 bpm · top 165 bpm'), findsOneWidget);
    expect(find.text('10 min · avg 120 bpm · top 150 bpm · 90 kcal'), findsOneWidget);
    expect(totalText(t), '2 sessions · 40 min · avg 135 bpm · top 165 bpm · 90 kcal');
  });

  testWidgets('wellbeing: 7 days of device signals, gaps shown, averages', (t) async {
    await pumpView(
        t,
        ViewKind.wellbeing,
        deps(signals: const [
          DailySignals(day: '2026-10-28', sleepMinutes: 420, steps: 8000, restingHr: 54),
          DailySignals(day: '2026-10-25', sleepMinutes: 480, steps: 6000),
        ]));
    expect(find.text('22 Oct'), findsOneWidget);
    expect(find.text('28 Oct'), findsOneWidget);
    expect(find.text('7 h'), findsOneWidget);
    expect(find.text('8,000'), findsOneWidget);
    expect(find.text('–'), findsWidgets);
    expect(totalText(t), '7-day average · sleep 7 h 30 min · 7,000 steps · resting HR 54 bpm');
  });

  testWidgets('wellbeing: a failed device read shows the empty state', (t) async {
    final d = LogViews(
      store: LogStore(InMemoryStateStore()),
      server: FakeServerPort(),
      signals: () async => throw StateError('read_failed'),
      clock: () => today,
    );
    await pumpView(t, ViewKind.wellbeing, d);
    expect(find.byKey(LogKeys.empty), findsOneWidget);
  });

  testWidgets('overview: one line per kind', (t) async {
    await pumpView(t, ViewKind.logs, deps(entries: [run, food]));
    expect(find.text('Runs'), findsOneWidget);
    expect(find.text('1 run · 5 km · 26:00 · average 5:12/km'), findsOneWidget);
    expect(find.text('Nothing logged'), findsNWidgets(3));
  });

  testWidgets('typed capture in a view: preview, tapped yes saves, row appears', (t) async {
    final server = FakeServerPort()..logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(run.toJson()));
    final d = deps(server: server);
    await pumpView(t, ViewKind.run, d);
    await t.enterText(find.byKey(LogKeys.field), '5 km in 26 min with splits');
    await t.tap(find.byKey(LogKeys.send));
    await t.pumpAndSettle();
    expect(find.text('Save?'), findsOneWidget);
    expect(await d.store.forDay(LogKind.run, day), isEmpty);
    await t.tap(find.byKey(LogKeys.saveYes));
    await t.pumpAndSettle();
    expect(find.text('Saved.'), findsOneWidget);
    expect(find.byKey(LogKeys.total), findsOneWidget);
    expect((await d.store.forDay(LogKind.run, day)).length, 1);
  });

  testWidgets('typed capture: tapped no saves nothing; crisis shows the referral', (t) async {
    final server = FakeServerPort()..logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(food.toJson()));
    final d = deps(server: server);
    await pumpView(t, ViewKind.food, d);
    await t.enterText(find.byKey(LogKeys.field), 'porridge 80 g');
    await t.tap(find.byKey(LogKeys.send));
    await t.pumpAndSettle();
    await t.tap(find.byKey(LogKeys.saveNo));
    await t.pumpAndSettle();
    expect(find.text('Not saved.'), findsOneWidget);
    expect(find.byKey(LogKeys.empty), findsOneWidget);

    server.logParseResult = const LogParseResult.crisis('Synthetic referral text.');
    await t.enterText(find.byKey(LogKeys.field), 'synthetic crisis line');
    await t.tap(find.byKey(LogKeys.send));
    await t.pumpAndSettle();
    expect(find.text('Synthetic referral text.'), findsOneWidget);
    expect(find.byKey(LogKeys.saveYes), findsNothing);
  });

  testWidgets('food preview: each item with its calories (est. on an estimate) and the entry total', (t) async {
    final env = envelope('food', {
      'meal': 'lunch',
      'items': [
        {'name': 'cooked rice', 'quantity': 200, 'unit': 'g', 'kcal': 260, 'kcal_estimated': true},
        {'name': 'eggs', 'quantity': 2, 'unit': 'piece', 'kcal': 144, 'kcal_estimated': true},
        {'name': 'whole milk', 'quantity': 250, 'unit': 'ml', 'kcal': 150},
      ],
    });
    final server = FakeServerPort()..logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(env));
    final d = deps(server: server);
    await pumpView(t, ViewKind.food, d);
    await t.enterText(find.byKey(LogKeys.field), '200 g cooked rice and two eggs for lunch, 250 ml whole milk 150 kcal');
    await t.tap(find.byKey(LogKeys.send));
    await t.pumpAndSettle();
    expect(find.text('200 g · 260 kcal est.'), findsOneWidget);
    expect(find.text('2 pieces · 144 kcal est.'), findsOneWidget);
    expect(find.text('250 ml · 150 kcal'), findsOneWidget);
    final total = t.widget<Text>(find.descendant(of: find.byKey(LogKeys.previewTotal), matching: find.byType(Text)));
    expect(total.textSpan!.toPlainText(), '3 items · 554 kcal in all · 150 kcal stated for 1 of 3 · 2 estimated (404 kcal)');
    expect(find.byKey(LogKeys.total), findsNothing);
    await t.tap(find.byKey(LogKeys.saveYes));
    await t.pumpAndSettle();
    expect(find.byKey(LogKeys.previewTotal), findsNothing);
    expect(totalText(t), '3 items · 554 kcal in all · 150 kcal stated for 1 of 3 · 2 estimated (404 kcal)');
    expect(t.takeException(), isNull);
  });

  testWidgets('previous day shows that day; close calls back', (t) async {
    await pumpView(t, ViewKind.run, deps(entries: [run]));
    expect(find.byKey(LogKeys.nextDay), findsNothing);
    await t.tap(find.byKey(LogKeys.prevDay));
    await t.pumpAndSettle();
    expect(find.text('Tuesday 27 October'), findsOneWidget);
    expect(find.byKey(LogKeys.empty), findsOneWidget);
    await t.tap(find.byKey(LogKeys.nextDay));
    await t.pumpAndSettle();
    expect(find.byKey(LogKeys.total), findsOneWidget);
    final before = closed;
    await t.tap(find.byKey(LogKeys.close));
    expect(closed, before + 1);
  });

  testWidgets('food mismatch renders the choice rows; a pick leads to Save? with nothing stored', (t) async {
    final server = FakeServerPort()..cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice]);
    final d = deps(server: server);
    await pumpView(t, ViewKind.food, d);
    await t.enterText(find.byKey(LogKeys.field), 'porridge 80 g');
    await t.tap(find.byKey(LogKeys.send));
    await t.pumpAndSettle();
    expect(find.textContaining('You wrote 300 kcal'), findsOneWidget);
    expect(find.textContaining('Synthetic Source lists 420 kcal'), findsOneWidget);
    expect(find.text('example.test'), findsOneWidget);
    expect(find.byKey(LogKeys.keepMine(0)), findsOneWidget);
    expect(find.byKey(LogKeys.saveYes), findsNothing);

    await t.tap(find.byKey(LogKeys.useFound(0)));
    await t.pumpAndSettle();
    expect(find.text('Save?'), findsOneWidget);
    expect(await d.store.forDay(LogKind.food, day), isEmpty);
    await t.tap(find.byKey(LogKeys.saveYes));
    await t.pumpAndSettle();
    expect(((await d.store.forDay(LogKind.food, day)).single as FoodEntry).items.first.kcal, 420);
    expect(find.textContaining('420 kcal'), findsWidgets);
  });

  testWidgets('a matched check shows one line in the preview', (t) async {
    final env = Map<String, dynamic>.from(run.toJson())
      ..['check'] = [
        {'item_index': 0, 'status': 'match', 'source_title': 'Synthetic Source'},
      ];
    final server = FakeServerPort()..logParseResult = LogParseResult.parsed(env);
    await pumpView(t, ViewKind.run, deps(server: server));
    await t.enterText(find.byKey(LogKeys.field), '5 km in 26 min');
    await t.tap(find.byKey(LogKeys.send));
    await t.pumpAndSettle();
    expect(find.byKey(LogKeys.checked), findsOneWidget);
    expect(find.text('Checked against Synthetic Source'), findsOneWidget);
  });

  testWidgets('fits a 360 px phone with 16 px gutters and no overflow', (t) async {
    await pumpView(t, ViewKind.run, deps(entries: [run, run]));
    expect(t.takeException(), isNull);
    final field = t.getRect(find.byKey(LogKeys.field));
    expect(field.left, greaterThanOrEqualTo(16));
    expect(t.getRect(find.byKey(LogKeys.send)).right, lessThanOrEqualTo(360 - 16));
  });

  test('view text, hint and figures meet 4.5:1 on the sheet over white or black, night and day', () {
    // Before the sky has been looked at the sheet is at the worst-case
    // alpha; with a look it is solved per sky (tokens_test).
    for (final p in [Palette.night, Palette.day]) {
      for (final under in [const Color(0xFFFFFFFF), const Color(0xFF000000)]) {
        final bg = composite(p.glass, GlassSpec.unknown, under);
        for (final ink in p.texts) {
          expect(contrast(ink, bg), greaterThanOrEqualTo(4.5), reason: '$ink over $under');
        }
      }
    }
  });
}
