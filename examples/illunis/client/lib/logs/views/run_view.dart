/// The run log for one day: distance, time and pace per run, a split table
/// (split time, elapsed time, and pace where the split distance was
/// stated), and one total line. Pace is computed here, never by the model.
/// Opened only through ViewHost.
library;

import 'package:flutter/material.dart';

import '../log_entry.dart';
import '../log_math.dart';
import 'log_frame.dart';

String _runLine(RunEntry r) {
  final p = runPace(r);
  return [
    '${numText(r.distance.value, digits: 2)} ${r.distance.unit}',
    clock(r.durationS),
    if (p != null) paceText(p, r.distance.unit),
  ].join(' · ');
}

Widget splitTable(RunEntry r) {
  final unit = r.distance.unit;
  return LogTable(
    header: ['#', unit, 'Split', 'Elapsed', 'Pace'],
    rows: [
      for (final s in splitRows(r))
        [
          '${s.index}',
          s.distance == null ? '–' : numText(s.distance!, digits: 2),
          clock(s.durationS),
          clock(s.elapsedS),
          s.paceS == null ? '–' : clock(s.paceS!),
        ],
    ],
    // Too narrow for five columns: "Split 2" · "1 km · 5:20 · elapsed 10:30 · 5:20/km".
    stacked: (row) => (
      'Split ${row[0]}',
      [
        if (row[1] != '–') '${row[1]} $unit',
        row[2],
        'elapsed ${row[3]}',
        if (row[4] != '–') '${row[4]}/$unit',
      ].join(' · '),
    ),
  );
}

List<Widget> runRows(List<LogEntry> entries) => [
      for (final (i, r) in entries.whereType<RunEntry>().indexed) ...[
        LogRow('Run ${i + 1}', _runLine(r), strong: true),
        if (r.splits.isNotEmpty) splitTable(r),
      ],
    ];

String runTotal(List<LogEntry> entries) {
  final list = entries.whereType<RunEntry>().toList();
  final t = runTotals(list);
  return [
    '${list.length} run${list.length == 1 ? '' : 's'}',
    distanceText(t.distance),
    clock(t.durationS),
    if (t.paceS != null) 'average ${paceText(t.paceS!, t.unit!)}',
  ].join(' · ');
}

class RunView extends StatelessWidget {
  const RunView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line; the field's hint shows the example, so it is not said twice.
  static const emptyText = 'Type your distance and time below.';

  @override
  Widget build(BuildContext context) => LogDayView(
        kind: LogKind.run,
        title: 'Runs',
        deps: deps,
        onClose: onClose,
        rows: runRows,
        total: runTotal,
        emptyText: emptyText,
      );
}
