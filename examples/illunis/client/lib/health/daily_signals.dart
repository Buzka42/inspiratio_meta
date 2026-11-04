/// One local day of wearable signals from Health Connect, as the 21-day
/// analysis takes it: `{day, sleep_minutes, steps, resting_hr}`. Any value
/// may be null (no data that day). Pure Dart.
library;

final _dayRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// `yyyy-mm-dd` for the local calendar day of [d].
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The date of a `yyyy-mm-dd` key (local midnight), or null when malformed.
DateTime? parseDayKey(Object? s) {
  final m = s is String ? _dayRe.firstMatch(s) : null;
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final date = DateTime(y, mo, d);
  return date.month == mo && date.day == d ? date : null;
}

/// [v] as an int when it is a number within [lo]..[hi], else null.
int? _inRange(Object? v, int lo, int hi) {
  if (v is! num || v.isNaN || v.isInfinite) return null;
  final i = v.round();
  return i < lo || i > hi ? null : i;
}

class DailySignals {
  const DailySignals({required this.day, this.sleepMinutes, this.steps, this.restingHr});

  /// Local date, `yyyy-mm-dd`.
  final String day;

  /// Minutes asleep in sessions that ended on [day] (awake stages excluded).
  final int? sleepMinutes;
  final int? steps;

  /// Lowest heart rate of the day in bpm: a stand-in for resting heart rate
  /// until RestingHeartRateRecord is read.
  final int? restingHr;

  bool get isEmpty => sleepMinutes == null && steps == null && restingHr == null;

  Map<String, dynamic> toJson() =>
      {'day': day, 'sleep_minutes': sleepMinutes, 'steps': steps, 'resting_hr': restingHr};

  /// Null for a bad day key. Out-of-range values become null, so one broken
  /// record never skews the analysis.
  static DailySignals? fromJson(Object? j) {
    if (j is! Map || parseDayKey(j['day']) == null) return null;
    return DailySignals(
      day: j['day'] as String,
      sleepMinutes: _inRange(j['sleep_minutes'], 0, 24 * 60),
      steps: _inRange(j['steps'], 0, 200000),
      restingHr: _inRange(j['resting_hr'], 25, 220),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DailySignals &&
      other.day == day &&
      other.sleepMinutes == sleepMinutes &&
      other.steps == steps &&
      other.restingHr == restingHr;

  @override
  int get hashCode => Object.hash(day, sleepMinutes, steps, restingHr);
}
