/// Decides when the morning digest fires. Timezone-free: the caller supplies
/// local wall-clock values and stores the returned fire date itself.
library;

class LocalTime {
  const LocalTime(this.hour, this.minute)
      : assert(hour >= 0 && hour < 24),
        assert(minute >= 0 && minute < 60);
  final int hour;
  final int minute;
  int get minutesOfDay => hour * 60 + minute;
}

class LocalDate {
  const LocalDate(this.year, this.month, this.day);
  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => '$year-$month-$day';
}

/// Minutes after the alarm during which a missed check still fires the
/// digest. Later than this the morning digest is stale and is skipped.
const defaultCatchUpMinutes = 180;

/// True when the digest should play now: at or after [alarm] on [today],
/// within [catchUpMinutes], and not already fired on [today].
/// The window never crosses midnight; a new date starts a new day.
bool shouldFireDigest({
  required LocalTime alarm,
  required LocalTime now,
  required LocalDate today,
  LocalDate? lastFired,
  int catchUpMinutes = defaultCatchUpMinutes,
}) {
  if (lastFired == today) return false;
  final late = now.minutesOfDay - alarm.minutesOfDay;
  return late >= 0 && late <= catchUpMinutes;
}
