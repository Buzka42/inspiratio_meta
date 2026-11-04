/// The strength log for one day: each exercise with its sets as reps times
/// weight, effort (RIR or RPE) only on sets where the user logged it, the
/// exercise volume, and one session total. Opened only through ViewHost.
library;

import 'package:flutter/material.dart';

import '../../ui/tokens.dart';
import '../log_entry.dart';
import '../log_math.dart';
import 'log_frame.dart';

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// `10 × 80 kg`, `12 × bodyweight`, `5 × 100 kg · RIR 2`.
String setText(StrengthSet s) {
  final load = s.weight == null ? 'bodyweight' : '${numText(s.weight!)} ${s.unit ?? 'kg'}';
  final effort = s.effort == null ? '' : ' · ${s.effort!.scale.toUpperCase()} ${numText(s.effort!.value)}';
  return '${s.reps} × $load$effort';
}

List<Widget> strengthRows(List<LogEntry> entries) => [
      for (final x in entries.whereType<StrengthEntry>().expand((e) => e.exercises)) ...[
        LogRow(_cap(x.name), volumeText(exerciseVolume(x)), strong: true),
        for (final (i, s) in x.sets.indexed)
          LogLine('Set ${i + 1}: ${setText(s)}', padding: const EdgeInsets.only(left: Space.s12)),
      ],
    ];

String strengthTotal(List<LogEntry> entries) {
  final list = entries.whereType<StrengthEntry>().toList();
  final vol = sessionVolume(list);
  final sets = totalSets(list);
  return [
    '$sets set${sets == 1 ? '' : 's'}',
    '${totalReps(list)} reps',
    if (vol.isNotEmpty) 'volume ${volumeText(vol)}',
  ].join(' · ');
}

class StrengthView extends StatelessWidget {
  const StrengthView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line; the field's hint shows the example, so it is not said twice.
  static const emptyText = 'Type an exercise with reps and weight.';

  @override
  Widget build(BuildContext context) => LogDayView(
        kind: LogKind.strength,
        title: 'Strength',
        deps: deps,
        onClose: onClose,
        rows: strengthRows,
        total: strengthTotal,
        emptyText: emptyText,
      );
}
