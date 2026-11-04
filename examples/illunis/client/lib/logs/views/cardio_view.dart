/// The cardio log for one day: each session with duration, average and top
/// heart rate, and calories only when logged, and one total line. The
/// averages are computed here, never by the model. Opened only through
/// ViewHost.
library;

import 'package:flutter/material.dart';

import '../log_entry.dart';
import '../log_math.dart';
import 'log_frame.dart';

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _detail(CardioEntry e) => [
      if (e.durationS != null) hoursMinutes(e.durationS!),
      if (e.hrAvg != null) 'avg ${e.hrAvg} bpm',
      if (e.hrMax != null) 'top ${e.hrMax} bpm',
      if (e.kcal != null) '${numText(e.kcal!)} kcal',
    ].join(' · ');

List<Widget> cardioRows(List<LogEntry> entries) =>
    [for (final e in entries.whereType<CardioEntry>()) LogRow(_cap(e.type), _detail(e))];

String cardioTotal(List<LogEntry> entries) {
  final list = entries.whereType<CardioEntry>().toList();
  final t = cardioTotals(list);
  return [
    '${list.length} session${list.length == 1 ? '' : 's'}',
    if (t.durationS > 0) hoursMinutes(t.durationS),
    if (t.hrAvg != null) 'avg ${t.hrAvg!.round()} bpm',
    if (t.hrMax != null) 'top ${t.hrMax} bpm',
    if (t.kcal != null) '${numText(t.kcal!)} kcal',
  ].join(' · ');
}

class CardioView extends StatelessWidget {
  const CardioView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line; the field's hint shows the example, so it is not said twice.
  static const emptyText = 'Type a session and its time below.';

  @override
  Widget build(BuildContext context) => LogDayView(
        kind: LogKind.cardio,
        title: 'Cardio',
        deps: deps,
        onClose: onClose,
        rows: cardioRows,
        total: cardioTotal,
        emptyText: emptyText,
      );
}
