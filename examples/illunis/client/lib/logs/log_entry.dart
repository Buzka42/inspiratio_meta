/// Structured log entries (build plan B6), in the envelope the Worker's
/// POST /log/parse returns: `{schema:"illunis.log/1", kind, date, source,
/// entry}`. Field names and enums follow server/src/logs/schemas.js, which
/// is the source of truth. The model only extracts; totals, pace and
/// averages are computed on the phone (log_math.dart). Pure Dart.
library;

import '../health/daily_signals.dart' show parseDayKey;

const logSchema = 'illunis.log/1';

enum LogKind {
  food('food'),
  activity('activity'),
  strength('strength'),
  run('run'),
  cardio('cardio');

  const LogKind(this.wire);

  /// The `kind` string on the wire.
  final String wire;

  static LogKind? fromWire(Object? s) => values.where((k) => k.wire == s).firstOrNull;
}

enum LogSource {
  typed('typed'),
  healthConnect('health_connect');

  const LogSource(this.wire);
  final String wire;

  static LogSource? fromWire(Object? s) => values.where((k) => k.wire == s).firstOrNull;
}

const foodMeals = ['breakfast', 'lunch', 'dinner', 'snack'];
const foodUnits = ['g', 'ml', 'piece', 'serving'];
const weightUnits = ['kg', 'lb'];
const runUnits = ['km', 'mi'];
const distanceUnits = ['km', 'mi', 'm'];
const effortScales = ['rir', 'rpe'];

// Small readers: each returns null for a missing or wrongly typed value.
double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _int(Object? v) => v is int ? v : (v is double && v == v.roundToDouble() && v.isFinite ? v.toInt() : null);
String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
String? _oneOf(Object? v, List<String> list) => v is String && list.contains(v) ? v : null;
List<Object?>? _list(Object? v) => v is List ? v : null;
Map<String, Object?>? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;

/// Thrown inside the readers; [LogEntry.fromJson] turns it into null.
class _Bad implements Exception {
  const _Bad();
}

T _need<T>(T? v) => v ?? (throw const _Bad());

/// A distance as the user stated it.
class Distance {
  const Distance(this.value, this.unit);
  final double value;

  /// `km`, `mi`, or `m` (activity only).
  final String unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit};

  static Distance _read(Object? j, List<String> units) {
    final m = _need(_map(j));
    final v = _need(_num(m['value']));
    if (v <= 0) throw const _Bad();
    return Distance(v, _need(_oneOf(m['unit'], units)));
  }

  @override
  bool operator ==(Object other) => other is Distance && other.value == value && other.unit == unit;
  @override
  int get hashCode => Object.hash(value, unit);
}

/// One log entry. The subclass is the `kind`; [date] is `yyyy-mm-dd`.
sealed class LogEntry {
  const LogEntry({required this.date, this.source = LogSource.typed});

  final String date;
  final LogSource source;

  LogKind get kind;

  /// The `entry` object.
  Map<String, Object?> entryJson();

  /// The full envelope.
  Map<String, Object?> toJson() =>
      {'schema': logSchema, 'kind': kind.wire, 'date': date, 'source': source.wire, 'entry': entryJson()};

  /// Reads an envelope (a /log/parse answer or a stored entry). Null when
  /// any field is missing, mistyped or outside the server's enums.
  static LogEntry? fromJson(Object? j) {
    final m = _map(j);
    if (m == null || m['schema'] != logSchema || parseDayKey(m['date']) == null) return null;
    final kind = LogKind.fromWire(m['kind']);
    final source = LogSource.fromWire(m['source']);
    final e = _map(m['entry']);
    if (kind == null || source == null || e == null) return null;
    final date = m['date'] as String;
    try {
      return switch (kind) {
        LogKind.food => FoodEntry._read(e, date, source),
        LogKind.activity => ActivityEntry._read(e, date, source),
        LogKind.strength => StrengthEntry._read(e, date, source),
        LogKind.run => RunEntry._read(e, date, source),
        LogKind.cardio => CardioEntry._read(e, date, source),
      };
    } on _Bad {
      return null;
    }
  }
}

class FoodItem {
  const FoodItem({required this.name, this.quantity, this.unit, this.kcal, this.estimated = false});
  final String name;
  final double? quantity;

  /// `g`, `ml`, `piece` or `serving`.
  final String? unit;

  /// Only when the user stated it, or when [estimated] is true.
  final double? kcal;

  /// True when [kcal] is an estimate from a web source (server kcal_estimated), not a figure the user stated.
  final bool estimated;

  Map<String, Object?> toJson() => {
        'name': name,
        if (quantity != null) 'quantity': quantity,
        if (unit != null) 'unit': unit,
        if (kcal != null) 'kcal': kcal,
        if (estimated) 'estimated': true,
      };

  static FoodItem _read(Object? j) {
    final m = _need(_map(j));
    final unit = m['unit'];
    return FoodItem(
      name: _need(_str(m['name'])),
      quantity: m['quantity'] == null ? null : _need(_num(m['quantity'])),
      unit: unit == null ? null : _need(_oneOf(unit, foodUnits)),
      kcal: m['kcal'] == null ? null : _need(_num(m['kcal'])),
      estimated: m['estimated'] == true || m['kcal_estimated'] == true,
    );
  }
}

class FoodEntry extends LogEntry {
  const FoodEntry({required super.date, super.source, this.meal, required this.items});

  /// `breakfast`, `lunch`, `dinner` or `snack`.
  final String? meal;
  final List<FoodItem> items;

  @override
  LogKind get kind => LogKind.food;

  @override
  Map<String, Object?> entryJson() =>
      {if (meal != null) 'meal': meal, 'items': [for (final i in items) i.toJson()]};

  static FoodEntry _read(Map<String, Object?> e, String date, LogSource source) {
    final items = _need(_list(e['items'])).map(FoodItem._read).toList();
    if (items.isEmpty) throw const _Bad();
    return FoodEntry(
      date: date,
      source: source,
      meal: e['meal'] == null ? null : _need(_oneOf(e['meal'], foodMeals)),
      items: items,
    );
  }
}

class ActivityEntry extends LogEntry {
  const ActivityEntry({required super.date, super.source, required this.type, this.durationS, this.distance, this.steps});

  final String type;
  final double? durationS;

  /// `km`, `mi` or `m`.
  final Distance? distance;
  final int? steps;

  @override
  LogKind get kind => LogKind.activity;

  @override
  Map<String, Object?> entryJson() => {
        'type': type,
        if (durationS != null) 'duration_s': durationS,
        if (distance != null) 'distance': distance!.toJson(),
        if (steps != null) 'steps': steps,
      };

  static ActivityEntry _read(Map<String, Object?> e, String date, LogSource source) => ActivityEntry(
        date: date,
        source: source,
        type: _need(_str(e['type'])),
        durationS: e['duration_s'] == null ? null : _need(_num(e['duration_s'])),
        distance: e['distance'] == null ? null : Distance._read(e['distance'], distanceUnits),
        steps: e['steps'] == null ? null : _need(_int(e['steps'])),
      );
}

/// Reps in reserve or RPE, kept only when the user logged it.
class Effort {
  const Effort(this.scale, this.value);

  /// `rir` or `rpe`.
  final String scale;
  final double value;

  Map<String, Object?> toJson() => {'scale': scale, 'value': value};

  static Effort _read(Object? j) {
    final m = _need(_map(j));
    return Effort(_need(_oneOf(m['scale'], effortScales)), _need(_num(m['value'])));
  }
}

class StrengthSet {
  const StrengthSet({required this.reps, this.weight, this.unit, this.effort});
  final int reps;

  /// Null for a bodyweight set.
  final double? weight;

  /// `kg` or `lb`; may be null for a bodyweight set.
  final String? unit;
  final Effort? effort;

  Map<String, Object?> toJson() =>
      {'reps': reps, 'weight': weight, 'unit': unit, if (effort != null) 'effort': effort!.toJson()};

  static StrengthSet _read(Object? j) {
    final m = _need(_map(j));
    final weight = m['weight'] == null ? null : _need(_num(m['weight']));
    final unit = m['unit'] == null ? null : _need(_oneOf(m['unit'], weightUnits));
    if (weight != null && unit == null) throw const _Bad();
    return StrengthSet(
      reps: _need(_int(m['reps'])),
      weight: weight,
      unit: unit,
      effort: m['effort'] == null ? null : Effort._read(m['effort']),
    );
  }
}

class Exercise {
  const Exercise({required this.name, required this.sets});
  final String name;
  final List<StrengthSet> sets;

  Map<String, Object?> toJson() => {'name': name, 'sets': [for (final s in sets) s.toJson()]};

  static Exercise _read(Object? j) {
    final m = _need(_map(j));
    final sets = _need(_list(m['sets'])).map(StrengthSet._read).toList();
    if (sets.isEmpty) throw const _Bad();
    return Exercise(name: _need(_str(m['name'])), sets: sets);
  }
}

class StrengthEntry extends LogEntry {
  const StrengthEntry({required super.date, super.source, required this.exercises});
  final List<Exercise> exercises;

  @override
  LogKind get kind => LogKind.strength;

  @override
  Map<String, Object?> entryJson() => {'exercises': [for (final e in exercises) e.toJson()]};

  static StrengthEntry _read(Map<String, Object?> e, String date, LogSource source) {
    final ex = _need(_list(e['exercises'])).map(Exercise._read).toList();
    if (ex.isEmpty) throw const _Bad();
    return StrengthEntry(date: date, source: source, exercises: ex);
  }
}

class RunSplit {
  const RunSplit({required this.index, this.distance, required this.durationS});

  /// 1-based position.
  final int index;

  /// In the run's unit; only when the user stated it.
  final double? distance;
  final double durationS;

  Map<String, Object?> toJson() => {'index': index, 'distance': distance, 'duration_s': durationS};

  static RunSplit _read(Object? j) {
    final m = _need(_map(j));
    return RunSplit(
      index: _need(_int(m['index'])),
      distance: m['distance'] == null ? null : _need(_num(m['distance'])),
      durationS: _need(_num(m['duration_s'])),
    );
  }
}

class RunEntry extends LogEntry {
  const RunEntry({required super.date, super.source, required this.distance, required this.durationS, this.splits = const []});

  /// `km` or `mi`.
  final Distance distance;
  final double durationS;
  final List<RunSplit> splits;

  @override
  LogKind get kind => LogKind.run;

  @override
  Map<String, Object?> entryJson() =>
      {'distance': distance.toJson(), 'duration_s': durationS, 'splits': [for (final s in splits) s.toJson()]};

  static RunEntry _read(Map<String, Object?> e, String date, LogSource source) => RunEntry(
        date: date,
        source: source,
        distance: Distance._read(e['distance'], runUnits),
        durationS: _need(_num(e['duration_s'])),
        splits: e['splits'] == null ? const [] : _need(_list(e['splits'])).map(RunSplit._read).toList(),
      );
}

class CardioEntry extends LogEntry {
  const CardioEntry({required super.date, super.source, required this.type, this.durationS, this.hrAvg, this.hrMax, this.kcal});

  final String type;
  final double? durationS;
  final int? hrAvg;
  final int? hrMax;

  /// Only when the user logged it.
  final double? kcal;

  @override
  LogKind get kind => LogKind.cardio;

  @override
  Map<String, Object?> entryJson() => {
        'type': type,
        if (durationS != null) 'duration_s': durationS,
        if (hrAvg != null) 'hr_avg': hrAvg,
        if (hrMax != null) 'hr_max': hrMax,
        if (kcal != null) 'kcal': kcal,
      };

  static CardioEntry _read(Map<String, Object?> e, String date, LogSource source) => CardioEntry(
        date: date,
        source: source,
        type: _need(_str(e['type'])),
        durationS: e['duration_s'] == null ? null : _need(_num(e['duration_s'])),
        hrAvg: e['hr_avg'] == null ? null : _need(_int(e['hr_avg'])),
        hrMax: e['hr_max'] == null ? null : _need(_int(e['hr_max'])),
        kcal: e['kcal'] == null ? null : _need(_num(e['kcal'])),
      );
}
