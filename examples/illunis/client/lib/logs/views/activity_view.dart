/// The activity log for one day: each activity with its time, distance and
/// steps as logged, and one total line. Opened only through ViewHost.
library;

import 'package:flutter/material.dart';

import '../log_entry.dart';
import '../log_math.dart';
import 'log_frame.dart';

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _detail(ActivityEntry e) => [
      if (e.durationS != null) hoursMinutes(e.durationS!),
      if (e.distance != null) '${numText(e.distance!.value, digits: 2)} ${e.distance!.unit}',
      if (e.steps != null) '${numText(e.steps!.toDouble())} steps',
    ].join(' · ');

List<Widget> activityRows(List<LogEntry> entries) =>
    [for (final e in entries.whereType<ActivityEntry>()) LogRow(_cap(e.type), _detail(e))];

String activityTotal(List<LogEntry> entries) {
  final list = entries.whereType<ActivityEntry>().toList();
  final t = activityTotals(list);
  return [
    '${list.length} activit${list.length == 1 ? 'y' : 'ies'}',
    if (t.durationS > 0) hoursMinutes(t.durationS),
    if (t.distance.isNotEmpty) distanceText(t.distance),
    if (t.steps > 0) '${numText(t.steps.toDouble())} steps',
  ].join(' · ');
}

class ActivityView extends StatelessWidget {
  const ActivityView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line; the field's hint shows the example, so it is not said twice.
  static const emptyText = 'Type an activity and its time below.';

  @override
  Widget build(BuildContext context) => LogDayView(
        kind: LogKind.activity,
        title: 'Activity',
        deps: deps,
        onClose: onClose,
        rows: activityRows,
        total: activityTotal,
        emptyText: emptyText,
      );
}
