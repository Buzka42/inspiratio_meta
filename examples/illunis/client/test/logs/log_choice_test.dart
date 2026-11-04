// Food calorie check: needs_choice answers, the pick flow, and the rule that
// nothing is written to LogStore before the user's yes. Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/logs/log_capture.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_store.dart';

import 'log_fixtures.dart';

Map<String, dynamic> choiceBody(List<Object?> rows) =>
    {'ok': false, 'code': 'needs_choice', 'pending': pendingFood, 'needs_choice': rows};

Map<String, Object?> rowJson(FoodChoice c) => {
      'item_index': c.itemIndex,
      'field': 'kcal',
      'user_value': c.userValue,
      'found_value': c.foundValue,
      'source_url': c.sourceUrl,
      'source_title': c.sourceTitle,
    };

({LogCapture capture, FakeServerPort server, LogStore store, List<String> logs}) rig() {
  final server = FakeServerPort();
  final store = LogStore(InMemoryStateStore());
  final logs = <String>[];
  final capture = LogCapture(kind: LogKind.food, server: server, store: store, date: () => day, log: logs.add);
  return (capture: capture, server: server, store: store, logs: logs);
}

double? kcalOf(LogEntry? e, int i) => (e as FoodEntry).items[i].kcal;

void main() {
  group('LogParseResult.fromJson', () {
    test('needs_choice with rows is a choice, not a rejection', () {
      final r = LogParseResult.fromJson(choiceBody([rowJson(porridgeChoice)]))!;
      expect(r.code, 'needs_choice');
      expect((r.ok, r.envelope), (false, null));
      expect(r.pending!['kind'], 'food');
      expect(r.choices.single.foundValue, 420);
      expect(r.choices.single.sourceTitle, 'Synthetic Source');
    });

    test('the old shape (ok false, a fixed code, no list) is still a rejection', () {
      final r = LogParseResult.fromJson({'ok': false, 'code': 'number_not_in_text'})!;
      expect(r.code, 'number_not_in_text');
      expect(r.pending, isNull);
      expect(r.choices, isEmpty);
      final bare = LogParseResult.fromJson({'ok': false, 'code': 'needs_choice'})!;
      expect(bare.code, 'needs_choice');
      expect(bare.pending, isNull);
    });

    test('a malformed row is a rejection, never a half-read choice', () {
      final bad = rowJson(porridgeChoice)..['field'] = 'protein';
      expect(LogParseResult.fromJson(choiceBody([bad]))!.pending, isNull);
      expect(LogParseResult.fromJson(choiceBody([]))!.pending, isNull);
    });
  });

  test('keep mine, then use found: the entry moves to the preview, unsaved', () async {
    final r = rig();
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice, coffeeChoice]);
    await r.capture.submit('porridge 80 g and a coffee');
    expect(r.capture.state, isA<CaptureChoice>());
    expect((r.capture.state as CaptureChoice).choices, hasLength(2));

    r.capture.chooseOne(porridgeChoice, useFound: true);
    expect((r.capture.state as CaptureChoice).choices, [coffeeChoice]);

    r.capture.chooseOne(coffeeChoice, useFound: false);
    final preview = r.capture.state as CapturePreview;
    expect((kcalOf(preview.entry, 0), kcalOf(preview.entry, 1)), (420, 90));
    expect(await r.store.forDay(LogKind.food, day), isEmpty);

    await r.capture.answer(true);
    final saved = await r.store.forDay(LogKind.food, day);
    expect(kcalOf(saved.single, 0), 420);
    expect(kcalOf(saved.single, 1), 90);
    expect(r.logs.join('\n'), isNot(contains('Synthetic Source')));
  });

  test('a used source figure is labelled an estimate; a kept one stays stated', () async {
    final r = rig();
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice, coffeeChoice]);
    await r.capture.submit('porridge 80 g and a coffee');
    r.capture.chooseOne(porridgeChoice, useFound: true);
    r.capture.chooseOne(coffeeChoice, useFound: false);
    final items = ((r.capture.state as CapturePreview).entry as FoodEntry).items;
    expect([for (final i in items) (i.kcal, i.estimated)], [(420, true), (90, false)]);
  });

  test('reset drops an open choice or a parse in flight, unsaved and silent', () async {
    final r = rig();
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice]);
    await r.capture.submit('porridge 80 g and a coffee');
    r.capture.reset();
    expect(r.capture.state, isA<CaptureIdle>());
    final pending = r.capture.submit('porridge 80 g and a coffee');
    r.capture.reset();
    await pending;
    expect(r.capture.state, isA<CaptureIdle>());
    expect(await r.store.forDay(LogKind.food, day), isEmpty);
  });

  test('typed "mine" keeps every number; typed "source" uses every found one', () async {
    final r = rig();
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice, coffeeChoice]);
    await r.capture.submit('porridge 80 g and a coffee');
    await r.capture.submit('source');
    expect((kcalOf((r.capture.state as CapturePreview).entry, 0), kcalOf((r.capture.state as CapturePreview).entry, 1)),
        (420, 5));

    await r.capture.submit('porridge 80 g and a coffee');
    await r.capture.submit('mine');
    expect((kcalOf((r.capture.state as CapturePreview).entry, 0), kcalOf((r.capture.state as CapturePreview).entry, 1)),
        (300, 90));
  });

  test('discard saves nothing and says so', () async {
    final r = rig();
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice]);
    await r.capture.submit('porridge 80 g');
    r.capture.discardChoice();
    expect((r.capture.state as CaptureMessage).text, CaptureText.discarded);
    expect(await r.store.forDay(LogKind.food, day), isEmpty);
  });

  test('a row that points past the items is refused, nothing is kept', () async {
    final r = rig();
    final off = FoodChoice(itemIndex: 7, userValue: 300, foundValue: 420, sourceTitle: 'Synthetic Source');
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [off]);
    await r.capture.submit('porridge 80 g');
    expect((r.capture.state as CaptureMessage).text, CaptureText.forCode('bad_field', LogKind.food));
    expect(await r.store.forDay(LogKind.food, day), isEmpty);
  });

  test('a matched check names its source in the preview; an unverified one does not', () async {
    final r = rig();
    final env = Map<String, dynamic>.from(food.toJson())
      ..['check'] = [
        {'item_index': 0, 'status': 'match', 'source_title': 'Synthetic Source', 'source_url': 'https://example.test/p'},
        {'item_index': 1, 'status': 'unverified'},
      ];
    r.server.logParseResult = LogParseResult.parsed(env);
    await r.capture.submit('porridge 80 g and a coffee');
    expect((r.capture.state as CapturePreview).checkedAgainst, 'Synthetic Source');

    final plain = Map<String, dynamic>.from(food.toJson())..['check'] = [{'item_index': 0, 'status': 'unverified'}];
    r.server.logParseResult = LogParseResult.parsed(plain);
    await r.capture.submit('porridge 80 g');
    expect((r.capture.state as CapturePreview).checkedAgainst, isNull);
  });

  test('a typed line other than mine or source is a new line', () async {
    final r = rig();
    r.server.cannedLogChoice(Map<String, dynamic>.from(pendingFood), [porridgeChoice]);
    await r.capture.submit('porridge 80 g');
    r.server.logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(food.toJson()));
    await r.capture.submit('a coffee after lunch');
    expect(r.capture.state, isA<CapturePreview>());
    expect(await r.store.forDay(LogKind.food, day), isEmpty);
  });
}
