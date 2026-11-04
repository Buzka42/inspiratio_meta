/// Sleep, steps and resting heart rate for the last 7 days, read straight
/// from the device's daily signals (Health Connect). No model is involved
/// and nothing is sent anywhere. Opened only through ViewHost.
library;

import 'package:flutter/material.dart';

import '../../health/daily_signals.dart';
import '../log_math.dart';
import 'log_frame.dart';

const wellbeingDays = 7;

String _sleep(int? m) => m == null ? '–' : hoursMinutes(m * 60.0);

class WellbeingView extends StatefulWidget {
  const WellbeingView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line: what to do to see sleep, steps and heart rate here.
  static const emptyText = 'Allow Health Connect in setup to see this.';

  @override
  State<WellbeingView> createState() => _WellbeingViewState();
}

class _WellbeingViewState extends State<WellbeingView> {
  List<DailySignals>? _days;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<DailySignals> signals;
    try {
      signals = await widget.deps.signals?.call() ?? const [];
    } catch (_) {
      // A failed device read shows the empty state; the code is logged by the health port.
      signals = const [];
    }
    if (!mounted) return;
    setState(() => _days = lastDays(signals, widget.deps.clock(), days: wellbeingDays));
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;
    final today = widget.deps.clock();
    final first = DateTime(today.year, today.month, today.day - (wellbeingDays - 1));
    return LogScaffold(
      title: 'Wellbeing',
      day: 'Last 7 days, ${shortDayLabel(first)} to ${shortDayLabel(today)}',
      onClose: widget.onClose,
      body: days == null
          ? const SizedBox.shrink()
          : ListView(padding: EdgeInsets.zero, children: [
              if (days.every((d) => d.isEmpty))
                const LogEmpty(WellbeingView.emptyText)
              else ...[
                LogTable(
                  header: const ['Day', 'Sleep', 'Steps', 'Resting HR'],
                  rows: [
                    for (final d in days)
                      [
                        shortDayLabel(parseDayKey(d.day)!),
                        _sleep(d.sleepMinutes),
                        d.steps == null ? '–' : numText(d.steps!.toDouble()),
                        d.restingHr == null ? '–' : '${d.restingHr}',
                      ],
                  ],
                  // Too narrow for four columns: "24 Oct" · "sleep 7 h 35 min · 12,345 steps · resting HR 53 bpm".
                  stacked: (row) {
                    final parts = [
                      if (row[1] != '–') 'sleep ${row[1]}',
                      if (row[2] != '–') '${row[2]} steps',
                      if (row[3] != '–') 'resting HR ${row[3]} bpm',
                    ];
                    return (row[0], parts.isEmpty ? '–' : parts.join(' · '));
                  },
                ),
                LogTotal(_total(days)),
              ],
            ]),
    );
  }

  String _total(List<DailySignals> days) {
    final a = signalAverages(days);
    return [
      '7-day average',
      if (a.sleepMinutes != null) 'sleep ${hoursMinutes(a.sleepMinutes! * 60)}',
      if (a.steps != null) '${numText(a.steps!.roundToDouble())} steps',
      if (a.restingHr != null) 'resting HR ${a.restingHr!.round()} bpm',
    ].join(' · ');
  }
}
