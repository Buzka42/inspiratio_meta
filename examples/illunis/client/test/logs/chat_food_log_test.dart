// Typed meal logging from the chat: a meal line goes to /log/parse (not the
// chat reply), the preview shows each item, its calories and the total, and
// only the Save? yes writes it. A mismatch shows both numbers and nothing is
// saved before the pick. Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/logs/chat_food_log.dart';
import 'package:illunis_client/logs/log_capture.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_store.dart';

import 'log_fixtures.dart';

const mealLine = 'I had 200 g cooked rice and two eggs for lunch';

/// The live answer's shape for [mealLine] (2026-10-30): both items estimated.
final riceAndEggs = envelope('food', {
  'meal': 'lunch',
  'items': [
    {'name': 'cooked rice', 'quantity': 200, 'unit': 'g', 'kcal': 260, 'kcal_estimated': true},
    {'name': 'eggs', 'quantity': 2, 'unit': 'piece', 'kcal': 144, 'kcal_estimated': true},
  ],
});

/// Rice written at 400 kcal; the source says 270. Eggs estimated.
final riceMismatch = envelope('food', {
  'meal': 'lunch',
  'items': [
    {'name': 'cooked rice', 'quantity': 200, 'unit': 'g', 'kcal': 400},
    {'name': 'eggs', 'quantity': 2, 'unit': 'piece', 'kcal': 144, 'kcal_estimated': true},
  ],
});

const riceChoice = FoodChoice(
    itemIndex: 0, userValue: 400, foundValue: 270, sourceUrl: 'https://example.test/rice', sourceTitle: 'Synthetic Rice');

class Rig {
  Rig({LogParseResult? result}) {
    if (result != null) server.logParseResult = result;
  }
  final server = FakeServerPort();
  final store = LogStore(InMemoryStateStore());
  final thread = ChatThread();
  final logs = <String>[];
  late final flow = ChatFoodLog(
    capture: LogCapture(kind: LogKind.food, server: server, store: store, date: () => day, log: logs.add),
    chat: ChatLogPort(
      say: thread.addAssistant,
      ask: thread.addOffer,
      close: (id, a) => thread.closeOffer(id, a == true ? OfferState.accepted : (a == false ? OfferState.declined : OfferState.closed)),
      note: thread.attachSources,
    ),
    log: logs.add,
  );

  /// A typed turn as the app runs it: the bubble, then the hook.
  Future<bool> type(String text) async {
    thread.addUser(text);
    final taken = flow.claim(text);
    await pumpEventQueue();
    return taken;
  }

  ChatEntry? get openOffer => thread.entries.where((e) => e.offer?.isOpen ?? false).lastOrNull;
  String get texts => thread.entries.map((e) => e.text).join('\n');
  Future<List<LogEntry>> get saved => store.forDay(LogKind.food, day);
}

void main() {
  group('isMealLine', () {
    test('lines that say what was eaten are meal lines', () {
      for (final t in [
        mealLine,
        'I ate a banana',
        "I've just eaten porridge 80 g",
        'had 2 slices of toast',
        'For lunch I had soup and bread',
        'Breakfast: 2 eggs and coffee',
        'log 250 ml whole milk 150 kcal',
        'I drank a latte',
      ]) {
        expect(isMealLine(t), isTrue, reason: t);
      }
    });

    test('questions, view requests and other "had" lines are not', () {
      for (final t in [
        'I had a headache',
        'I had a long day at work',
        'how many calories are in rice?',
        'Should I eat before bed',
        'log my lunch',
        'show my food log',
        'log my run 5 km in 26 min',
        'a banana',
        'lunch was great',
        'yes',
        '',
      ]) {
        expect(isMealLine(t), isFalse, reason: t);
      }
    });
  });

  test('a meal line is parsed as food; the preview lists items, calories with est., the total, then Save?', () async {
    final r = Rig(result: LogParseResult.parsed(riceAndEggs));
    expect(await r.type(mealLine), isTrue);
    expect(r.server.logParseCalls.single.kind, 'food');
    expect(r.server.logParseCalls.single.text, mealLine);
    expect(r.server.calls, isNot(contains('/reply')));
    expect(r.texts, contains('Lunch\nCooked rice · 200 g · 260 kcal est.\nEggs · 2 pieces · 144 kcal est.'));
    expect(r.texts, contains('Total: 2 items · 2 estimated (404 kcal)'));
    expect(r.openOffer?.text, 'Save?');
    expect(r.openOffer?.offer?.choices, isNull);
    expect(await r.saved, isEmpty);
  });

  test('a typed yes saves the entry with its estimates; the chat says so', () async {
    final r = Rig(result: LogParseResult.parsed(riceAndEggs));
    await r.type(mealLine);
    final id = r.openOffer!.offer!.id;
    expect(await r.type('yes'), isTrue);
    final saved = (await r.saved).single as FoodEntry;
    expect(saved.meal, 'lunch');
    expect([for (final i in saved.items) (i.name, i.kcal, i.estimated)], [('cooked rice', 260, true), ('eggs', 144, true)]);
    expect(r.thread.entries.last.text, ChatLogText.saved);
    expect(r.thread.entries.firstWhere((e) => e.offer?.id == id).offer!.state, OfferState.accepted);
    expect(r.logs, isNot(contains(predicate<String>((l) => l.contains('rice')))));
  });

  test('a typed no saves nothing', () async {
    final r = Rig(result: LogParseResult.parsed(riceAndEggs));
    await r.type(mealLine);
    expect(await r.type('no'), isTrue);
    expect(await r.saved, isEmpty);
    expect(r.thread.entries.last.text, CaptureText.discarded);
  });

  test('a new turn drops the preview unsaved; a later yes saves nothing', () async {
    final r = Rig(result: LogParseResult.parsed(riceAndEggs));
    await r.type(mealLine);
    expect(await r.type('Synthetic question about sleep'), isFalse);
    expect(r.flow.active, isFalse);
    expect(await r.type('yes'), isFalse);
    expect(await r.saved, isEmpty);
  });

  test('a stated figure shows without est. and a match names its source', () async {
    final env = envelope('food', {
      'items': [
        {'name': 'whole milk', 'quantity': 250, 'unit': 'ml', 'kcal': 150},
      ],
    })
      ..['check'] = [
        {'item_index': 0, 'status': 'match', 'source_title': 'Synthetic Milk'},
      ];
    final r = Rig(result: LogParseResult.parsed(env));
    await r.type('log 250 ml whole milk 150 kcal');
    expect(r.texts, contains('Whole milk · 250 ml · 150 kcal\n'));
    expect(r.texts, isNot(contains('150 kcal est.')));
    expect(r.texts, contains('Total: 1 item · 150 kcal stated for 1 of 1'));
    expect(r.thread.entries.any((e) => e.sources == 'Checked against Synthetic Milk'), isTrue);
  });

  test('a mismatch shows both numbers as a choice; nothing is saved until the pick and the yes', () async {
    final r = Rig(result: LogParseResult.choice(Map<String, dynamic>.from(riceMismatch), [riceChoice]));
    await r.type('I had 200 g cooked rice 400 kcal and two eggs for lunch');
    final offer = r.openOffer!;
    expect(offer.text, contains('Cooked rice: you wrote 400 kcal. Synthetic Rice lists 270 kcal.'));
    expect(offer.text, contains('example.test'));
    expect(offer.offer!.choices, ['Keep mine (400)', 'Use 270']);
    expect(await r.saved, isEmpty);

    // A yes is not a pick.
    expect(await r.type('yes'), isFalse);
    expect(r.flow.active, isFalse);
    expect(await r.saved, isEmpty);

    await r.type('I had 200 g cooked rice 400 kcal and two eggs for lunch');
    expect(await r.type('Use 270'), isTrue);
    expect(r.texts, contains('Cooked rice · 200 g · 270 kcal est.'));
    expect(r.openOffer?.text, 'Save?');
    expect(await r.saved, isEmpty);
    await r.type('yes');
    final item = ((await r.saved).single as FoodEntry).items.first;
    expect((item.kcal, item.estimated), (270, true));
  });

  test('keep mine keeps the stated number, unlabelled', () async {
    final r = Rig(result: LogParseResult.choice(Map<String, dynamic>.from(riceMismatch), [riceChoice]));
    await r.type('I had 200 g cooked rice 400 kcal and two eggs for lunch');
    await r.type('Keep mine (400)');
    expect(r.texts, contains('Cooked rice · 200 g · 400 kcal\n'));
    expect(r.texts, contains('Total: 2 items · 544 kcal in all · 400 kcal stated for 1 of 2 · 1 estimated (144 kcal)'));
    await r.type('yes');
    final item = ((await r.saved).single as FoodEntry).items.first;
    expect((item.kcal, item.estimated), (400, false));
  });

  test('a no on the choice discards it', () async {
    final r = Rig(result: LogParseResult.choice(Map<String, dynamic>.from(riceMismatch), [riceChoice]));
    await r.type('I had 200 g cooked rice 400 kcal and two eggs for lunch');
    expect(await r.type('no'), isTrue);
    expect(r.thread.entries.last.text, CaptureText.discarded);
    expect(await r.saved, isEmpty);
  });

  test('an offer with choices keeps them through a save and reload, closed', () {
    final t = ChatThread()..addOffer('Pick one', 'log-1', choices: const ['Keep mine (400)', 'Use 270']);
    final again = ChatEntry.fromJson(t.entries.single.toJson())!;
    expect(again.offer!.choices, ['Keep mine (400)', 'Use 270']);
    expect(again.offer!.state, OfferState.closed);
    t.closeOffer('log-1', OfferState.accepted);
    expect(t.entries.single.offer!.choices, hasLength(2));
  });

  test('a failed parse says logging is unavailable and saves nothing', () async {
    final r = Rig()..server.logParseError = const ServerException(503, 'down');
    await r.type(mealLine);
    expect(r.thread.entries.last.text, CaptureText.unavailable);
    expect(await r.saved, isEmpty);
  });
}
