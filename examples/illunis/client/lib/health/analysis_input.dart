/// The body of POST /analysis/21d (server/src/analysis/, stateless):
/// `{checkins: [{day, mood, energy, sleep}], signals: [{day, sleep_minutes,
/// steps, resting_hr}], tz}`. Only the last [analysisDays] local days ending
/// today are included, oldest first, and days with no values are left out.
library;

import 'checkin.dart';
import 'daily_signals.dart';
import 'health_port.dart';
import 'imported_signals.dart';

const analysisDays = 21;

class AnalysisInput {
  const AnalysisInput({required this.checkins, required this.signals, required this.tz});
  final List<CheckIn> checkins;
  final List<DailySignals> signals;
  final String tz;

  bool get isEmpty => checkins.isEmpty && signals.isEmpty;

  Map<String, dynamic> toJson() => {
        'checkins': [for (final c in checkins) c.toJson()],
        'signals': [for (final s in signals) s.toJson()],
        'tz': tz,
      };

  /// Keeps the window ending on [today]'s local date.
  factory AnalysisInput.window({
    required List<CheckIn> checkins,
    required List<DailySignals> signals,
    required String tz,
    required DateTime today,
    int days = analysisDays,
  }) {
    final last = dayKey(today);
    final first = dayKey(DateTime(today.year, today.month, today.day - (days - 1)));
    bool inside(String d) => d.compareTo(first) >= 0 && d.compareTo(last) <= 0;
    List<T> pick<T>(List<T> xs, String Function(T) day, bool Function(T) empty) {
      final byDay = <String, T>{for (final x in xs) if (inside(day(x)) && !empty(x)) day(x): x};
      return [for (final k in byDay.keys.toList()..sort()) byDay[k] as T];
    }

    return AnalysisInput(
      checkins: pick(checkins, (c) => c.day, (c) => c.isEmpty),
      signals: pick(signals, (s) => s.day, (s) => s.isEmpty),
      tz: tz,
    );
  }
}

/// Reads stored check-ins and, when Health Connect is granted, 21 days of
/// signals. A failed or refused read leaves signals empty (logged as a code);
/// [fallbackTz] is used when no read gave a zone. Days from an owner import
/// ([imported]) fill in where Health Connect has none.
Future<AnalysisInput> collectAnalysisInput({
  required CheckInStore checkIns,
  required HealthPort health,
  required DateTime today,
  ImportedSignalsStore? imported,
  String fallbackTz = 'UTC',
  void Function(String line)? log,
}) async {
  var signals = const <DailySignals>[];
  var tz = fallbackTz;
  try {
    if (await health.hasPermissions()) {
      final r = await health.readDaily(days: analysisDays);
      signals = r.days;
      tz = r.tz;
    }
  } on HealthException catch (e) {
    log?.call('health: read_failed code=${e.code}');
  }
  final older = imported == null ? const <DailySignals>[] : await imported.all();
  // window() keeps the last entry per day, so Health Connect wins.
  return AnalysisInput.window(
      checkins: await checkIns.all(), signals: [...older, ...signals], tz: tz, today: today);
}
