/// Totals, volume, pace, splits and averages for the log views. The phone
/// computes these from the user's own numbers; the model never does
/// (build plan B6). Pure Dart.
library;

import '../health/daily_signals.dart';
import 'log_entry.dart';

// ---- food ----------------------------------------------------------------

/// Calories summed over items with a figure: stated by the user, or estimated (estimates are not counted in [stated]).
/// [stated] of [items] items carried a figure the user stated.
({double kcal, int stated, int items}) foodTotals(Iterable<FoodEntry> entries) {
  var kcal = 0.0;
  var stated = 0, items = 0;
  for (final e in entries) {
    for (final i in e.items) {
      items++;
      if (i.kcal case final k?) {
        kcal += k;
        if (!i.estimated) stated++;
      }
    }
  }
  return (kcal: kcal, stated: stated, items: items);
}

// ---- distance --------------------------------------------------------------

/// Distances summed per unit; metres are folded into kilometres. Miles
/// stay separate (no conversion of the user's unit).
Map<String, double> distanceTotals(Iterable<Distance> ds) {
  final out = <String, double>{};
  for (final d in ds) {
    final (unit, v) = d.unit == 'm' ? ('km', d.value / 1000) : (d.unit, d.value);
    out[unit] = (out[unit] ?? 0) + v;
  }
  return out;
}

// ---- activity --------------------------------------------------------------

({double durationS, Map<String, double> distance, int steps}) activityTotals(Iterable<ActivityEntry> entries) {
  final list = entries.toList();
  return (
    durationS: list.fold(0.0, (t, e) => t + (e.durationS ?? 0)),
    distance: distanceTotals(list.map((e) => e.distance).whereType<Distance>()),
    steps: list.fold(0, (t, e) => t + (e.steps ?? 0)),
  );
}

// ---- strength --------------------------------------------------------------

/// Reps times weight; null for a bodyweight set.
double? setVolume(StrengthSet s) => s.weight == null ? null : s.reps * s.weight!;

Map<String, double> _addVolume(Map<String, double> into, Iterable<StrengthSet> sets) {
  for (final s in sets) {
    final v = setVolume(s);
    if (v == null) continue;
    final unit = s.unit ?? 'kg';
    into[unit] = (into[unit] ?? 0) + v;
  }
  return into;
}

/// Volume of one exercise per weight unit (kg and lb are never mixed).
Map<String, double> exerciseVolume(Exercise e) => _addVolume({}, e.sets);

/// Volume of a session (one entry or a day's entries) per weight unit.
Map<String, double> sessionVolume(Iterable<StrengthEntry> entries) {
  final out = <String, double>{};
  for (final e in entries) {
    for (final x in e.exercises) {
      _addVolume(out, x.sets);
    }
  }
  return out;
}

int totalReps(Iterable<StrengthEntry> entries) =>
    entries.expand((e) => e.exercises).expand((x) => x.sets).fold(0, (t, s) => t + s.reps);

int totalSets(Iterable<StrengthEntry> entries) =>
    entries.expand((e) => e.exercises).fold(0, (t, x) => t + x.sets.length);

// ---- run -------------------------------------------------------------------

/// Seconds per unit of distance; null when [distance] is not positive.
double? pace(double durationS, double distance) => distance > 0 ? durationS / distance : null;

/// Seconds per km or per mile, in the run's own unit.
double? runPace(RunEntry r) => pace(r.durationS, r.distance.value);

class SplitRow {
  const SplitRow({required this.index, this.distance, required this.durationS, required this.elapsedS, this.paceS});
  final int index;

  /// In the run's unit, when stated.
  final double? distance;
  final double durationS;

  /// Time from the start to the end of this split.
  final double elapsedS;

  /// Seconds per run unit, only when the split distance was stated.
  final double? paceS;
}

/// The split table: each split with its elapsed time and, when its
/// distance is known, its pace.
List<SplitRow> splitRows(RunEntry r) {
  var elapsed = 0.0;
  return [
    for (final s in r.splits)
      SplitRow(
        index: s.index,
        distance: s.distance,
        durationS: s.durationS,
        elapsedS: elapsed += s.durationS,
        paceS: s.distance == null ? null : pace(s.durationS, s.distance!),
      ),
  ];
}

/// A day of runs: distance per unit, total time, and the average pace when
/// every run uses the same unit.
({Map<String, double> distance, double durationS, double? paceS, String? unit}) runTotals(Iterable<RunEntry> runs) {
  final list = runs.toList();
  final distance = distanceTotals(list.map((r) => r.distance));
  final durationS = list.fold(0.0, (t, r) => t + r.durationS);
  final unit = distance.length == 1 ? distance.keys.single : null;
  return (
    distance: distance,
    durationS: durationS,
    paceS: unit == null ? null : pace(durationS, distance[unit]!),
    unit: unit,
  );
}

// ---- cardio ----------------------------------------------------------------

/// Total time, average heart rate (weighted by duration when every session
/// with an average also has a duration, else a plain mean), top heart rate,
/// and calories summed over sessions that logged them (null when none did).
({double durationS, double? hrAvg, int? hrMax, double? kcal}) cardioTotals(Iterable<CardioEntry> entries) {
  final list = entries.toList();
  final withAvg = list.where((e) => e.hrAvg != null).toList();
  double? hrAvg;
  if (withAvg.isNotEmpty) {
    final weighted = withAvg.every((e) => (e.durationS ?? 0) > 0);
    if (weighted) {
      final t = withAvg.fold(0.0, (s, e) => s + e.durationS!);
      hrAvg = withAvg.fold(0.0, (s, e) => s + e.hrAvg! * e.durationS!) / t;
    } else {
      hrAvg = withAvg.fold(0.0, (s, e) => s + e.hrAvg!) / withAvg.length;
    }
  }
  final maxes = list.map((e) => e.hrMax).whereType<int>();
  final kcals = list.map((e) => e.kcal).whereType<double>();
  return (
    durationS: list.fold(0.0, (t, e) => t + (e.durationS ?? 0)),
    hrAvg: hrAvg,
    hrMax: maxes.isEmpty ? null : maxes.reduce((a, b) => a > b ? a : b),
    kcal: kcals.isEmpty ? null : kcals.fold<double>(0, (a, b) => a + b),
  );
}

// ---- wellbeing -------------------------------------------------------------

/// The last [days] local days ending on [today], oldest first, each with its
/// signals or an empty day when the device had none.
List<DailySignals> lastDays(Iterable<DailySignals> signals, DateTime today, {int days = 7}) {
  final byDay = {for (final s in signals) s.day: s};
  final end = DateTime(today.year, today.month, today.day);
  return [
    for (var i = days - 1; i >= 0; i--)
      () {
        final key = dayKey(DateTime(end.year, end.month, end.day - i));
        return byDay[key] ?? DailySignals(day: key);
      }(),
  ];
}

double? _mean(Iterable<int> xs) => xs.isEmpty ? null : xs.fold(0, (a, b) => a + b) / xs.length;

/// Means over the days that have a value.
({double? sleepMinutes, double? steps, double? restingHr}) signalAverages(Iterable<DailySignals> days) {
  final list = days.toList();
  return (
    sleepMinutes: _mean(list.map((d) => d.sleepMinutes).whereType<int>()),
    steps: _mean(list.map((d) => d.steps).whereType<int>()),
    restingHr: _mean(list.map((d) => d.restingHr).whereType<int>()),
  );
}

// ---- formatting ------------------------------------------------------------

/// `25:00` under an hour, `1:05:03` from an hour.
String clock(double seconds) {
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// `1 h 20 min`, `45 min`, `30 s`.
String hoursMinutes(double seconds) {
  final s = seconds.round();
  if (s < 60) return '$s s';
  // Round to whole minutes first, so 59.5 min is "1 h", never "60 min".
  final minutes = (s / 60).round();
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// `5:00/km`.
String paceText(double secondsPerUnit, String unit) => '${clock(secondsPerUnit)}/$unit';

/// A number without a trailing `.0`, at most [digits] decimals, with
/// thousands grouped (`1,389.5`).
String numText(double v, {int digits = 1}) {
  final fixed = v.toStringAsFixed(digits);
  final negative = fixed.startsWith('-');
  final parts = (negative ? fixed.substring(1) : fixed).split('.');
  final frac = parts.length > 1 ? parts[1].replaceFirst(RegExp(r'0+$'), '') : '';
  final whole = _grouped(int.parse(parts[0]));
  final out = frac.isEmpty ? whole : '$whole.$frac';
  return negative && out != '0' ? '-$out' : out;
}

String _grouped(int v) {
  final s = v.abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// `5.2 km · 3 mi`.
String distanceText(Map<String, double> byUnit) =>
    [for (final e in byUnit.entries) '${numText(e.value, digits: 2)} ${e.key}'].join(' · ');

/// `4,800 kg · 1,200 lb`.
String volumeText(Map<String, double> byUnit) => [for (final e in byUnit.entries) '${numText(e.value)} ${e.key}'].join(' · ');
