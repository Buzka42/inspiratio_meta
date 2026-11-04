// Synthetic log entries for the log tests. No real data.
import 'package:illunis_client/app/server_port.dart' show FoodChoice;
import 'package:illunis_client/logs/log_entry.dart';

const day = '2026-10-28';

Map<String, Object?> envelope(String kind, Map<String, Object?> entry, {String date = day}) =>
    {'schema': 'illunis.log/1', 'kind': kind, 'date': date, 'source': 'typed', 'entry': entry};

const food = FoodEntry(date: day, meal: 'breakfast', items: [
  FoodItem(name: 'porridge', quantity: 80, unit: 'g', kcal: 300),
  FoodItem(name: 'coffee'),
]);

const lunch = FoodEntry(date: day, meal: 'lunch', items: [FoodItem(name: 'soup', kcal: 250.5)]);

const walk = ActivityEntry(date: day, type: 'walk', durationS: 2400, distance: Distance(3.2, 'km'), steps: 4100);
const swim = ActivityEntry(date: day, type: 'swim', durationS: 1800, distance: Distance(800, 'm'));

const squat = Exercise(name: 'squat', sets: [
  StrengthSet(reps: 5, weight: 100, unit: 'kg'),
  StrengthSet(reps: 5, weight: 100, unit: 'kg', effort: Effort('rir', 2)),
  StrengthSet(reps: 5, weight: 100, unit: 'kg'),
]);
const pullup = Exercise(name: 'pull-up', sets: [StrengthSet(reps: 8), StrengthSet(reps: 6)]);
const strength = StrengthEntry(date: day, exercises: [squat, pullup]);

const run = RunEntry(date: day, distance: Distance(5, 'km'), durationS: 1560, splits: [
  RunSplit(index: 1, distance: 1, durationS: 310),
  RunSplit(index: 2, distance: 1, durationS: 320),
  RunSplit(index: 3, durationS: 315),
]);

const rowing = CardioEntry(date: day, type: 'rowing', durationS: 1800, hrAvg: 140, hrMax: 165);
const bike = CardioEntry(date: day, type: 'bike', durationS: 600, hrAvg: 120, hrMax: 150, kcal: 90);

// A food mismatch: porridge written at 300 kcal, the source says 420; the
// coffee's 90 kcal agrees with nothing to check. Synthetic values and URL.
final pendingFood = envelope('food', {
  'meal': 'breakfast',
  'items': [
    {'name': 'porridge', 'quantity': 80, 'unit': 'g', 'kcal': 300},
    {'name': 'coffee', 'kcal': 90},
  ],
});

const porridgeChoice = FoodChoice(
  itemIndex: 0,
  userValue: 300,
  foundValue: 420,
  sourceUrl: 'https://example.test/porridge',
  sourceTitle: 'Synthetic Source',
);

const coffeeChoice = FoodChoice(
  itemIndex: 1,
  userValue: 90,
  foundValue: 5,
  sourceUrl: 'https://example.test/coffee',
  sourceTitle: 'Synthetic Coffee Source',
);
