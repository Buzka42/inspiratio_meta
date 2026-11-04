/// "Show my logs": one total line per log kind for the day, read from
/// [LogStore]. Each kind's own view is a separate request and offer.
/// Opened only through ViewHost.
library;

import 'package:flutter/material.dart';

import '../../health/daily_signals.dart';
import '../log_entry.dart';
import 'activity_view.dart';
import 'cardio_view.dart';
import 'food_view.dart';
import 'log_frame.dart';
import 'run_view.dart';
import 'strength_view.dart';

const _names = {
  LogKind.food: 'Food',
  LogKind.activity: 'Activity',
  LogKind.strength: 'Strength',
  LogKind.run: 'Runs',
  LogKind.cardio: 'Cardio',
};

String _count(int n) => '$n entr${n == 1 ? 'y' : 'ies'} today';

String Function(List<LogEntry>) _totalOf(LogKind k) => switch (k) {
      LogKind.food => foodTotal,
      LogKind.activity => activityTotal,
      LogKind.strength => strengthTotal,
      LogKind.run => runTotal,
      LogKind.cardio => cardioTotal,
    };

class LogsDayView extends StatefulWidget {
  const LogsDayView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line: what to do when nothing is logged today.
  static const emptyText = 'Ask in the chat to log a meal or a run.';

  @override
  State<LogsDayView> createState() => _LogsDayViewState();
}

class _LogsDayViewState extends State<LogsDayView> {
  Map<LogKind, List<LogEntry>>? _byKind;

  @override
  void initState() {
    super.initState();
    widget.deps.store.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.deps.store.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final key = dayKey(widget.deps.clock());
    final out = {for (final k in LogKind.values) k: await widget.deps.store.forDay(k, key)};
    if (mounted) setState(() => _byKind = out);
  }

  @override
  Widget build(BuildContext context) {
    final byKind = _byKind;
    final today = widget.deps.clock();
    return LogScaffold(
      title: 'Logs',
      day: 'Today, ${dayLabel(today)}',
      onClose: widget.onClose,
      body: byKind == null
          ? const SizedBox.shrink()
          : ListView(padding: EdgeInsets.zero, children: [
              if (byKind.values.every((l) => l.isEmpty))
                const LogEmpty(LogsDayView.emptyText)
              else ...[
                for (final k in LogKind.values)
                  LogRow(_names[k]!, byKind[k]!.isEmpty ? 'Nothing logged' : _totalOf(k)(byKind[k]!), strong: true),
                LogTotal(_count(byKind.values.fold(0, (t, l) => t + l.length))),
              ],
            ]),
    );
  }
}
