/// Wake debounce: after an accepted wake, further wakes are ignored for
/// [wakeDebounce]. The window runs from the last accepted wake, so ignored
/// wakes do not extend it.
library;

import 'wake_engine.dart';

const wakeDebounce = Duration(seconds: 2);

/// True when a wake at [now] should be accepted, given the last accepted
/// wake at [lastAccepted] (null when none yet). Pure.
bool acceptWake(DateTime? lastAccepted, DateTime now,
    {Duration window = wakeDebounce}) {
  if (lastAccepted == null) return true;
  final gap = now.difference(lastAccepted);
  // A clock that went backwards is treated as a fresh wake.
  return gap.isNegative || gap >= window;
}

/// Filters [events] with [acceptWake], using each event's own time.
Stream<WakeEvent> debounceWakes(Stream<WakeEvent> events,
    {Duration window = wakeDebounce}) {
  DateTime? last;
  return events.where((e) {
    if (!acceptWake(last, e.time, window: window)) return false;
    last = e.time;
    return true;
  });
}
