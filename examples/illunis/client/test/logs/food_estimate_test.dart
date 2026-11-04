// Estimates for foods logged without a stated figure (owner, 2026-10-30): kept with their label, counted apart
// from stated figures, and shown as "est." in the food view.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_math.dart';
import 'package:illunis_client/logs/views/food_view.dart';

Map<String, Object?> envelope(Map<String, Object?> item) => {
      'schema': logSchema,
      'kind': 'food',
      'date': '2026-10-30',
      'source': 'typed',
      'entry': {'items': [item]},
    };

FoodItem readItem(Map<String, Object?> item) => (LogEntry.fromJson(envelope(item)) as FoodEntry).items.single;

void main() {
  test('a server estimate is read as estimated and survives a save and reload', () {
    final item = readItem({'name': 'toast', 'quantity': 1, 'unit': 'piece', 'kcal': 80, 'kcal_estimated': true});
    expect(item.estimated, isTrue);
    expect(item.kcal, 80);
    final again = readItem(item.toJson());
    expect(again.estimated, isTrue);
  });

  test('a stated figure is not marked estimated', () {
    expect(readItem({'name': 'eggs', 'kcal': 140}).estimated, isFalse);
  });

  test('totals count estimates in kcal but not in the stated count, and the line says so', () {
    final entry = FoodEntry(date: '2026-10-30', items: const [
      FoodItem(name: 'eggs', kcal: 140),
      FoodItem(name: 'toast', kcal: 80, estimated: true),
    ]);
    final t = foodTotals([entry]);
    expect(t.kcal, 220);
    expect(t.stated, 1);
    expect(t.items, 2);
    expect(foodTotal([entry]), '2 items · 220 kcal in all · 140 kcal stated for 1 of 2 · 1 estimated (80 kcal)');
  });

  test('only estimates shows the estimate count, not "no calories stated"', () {
    final entry = FoodEntry(date: '2026-10-30', items: const [FoodItem(name: 'toast', kcal: 80, estimated: true)]);
    expect(foodTotal([entry]), '1 item · 1 estimated (80 kcal)');
  });
}
