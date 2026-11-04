/// Calls [MorningFlow.tick] once a minute with the local wall clock.
/// The clock and the timer are injectable so tests advance time by hand.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../voice/alarm_digest.dart';
import 'morning_flow.dart';
import 'server_port.dart';

typedef Clock = DateTime Function();
typedef PeriodicTimerFactory = Timer Function(Duration period, void Function(Timer) onTick);

class DigestTicker {
  DigestTicker({
    required this.flow,
    Clock? clock,
    PeriodicTimerFactory? timer,
    this.period = const Duration(minutes: 1),
    this.findings,
    void Function(String line)? log,
  })  : _clock = clock ?? DateTime.now,
        _timer = timer ?? Timer.periodic,
        _log = log ?? debugPrint;

  final MorningFlow flow;
  final Duration period;

  /// Findings for the digest at fire time; none when null.
  final List<Finding> Function()? findings;

  final Clock _clock;
  final PeriodicTimerFactory _timer;
  final void Function(String) _log;
  Timer? _t;

  bool get running => _t != null;

  /// Checks once now (catch-up on open), then every [period].
  void start() {
    if (_t != null) return;
    _t = _timer(period, (_) => unawaited(check()));
    unawaited(check());
  }

  /// One check against the clock. Never throws; a failed digest call is
  /// retried on the next check because [MorningFlow] keeps lastFired unset.
  Future<DigestResult?> check() async {
    final now = _clock();
    try {
      return await flow.tick(
        now: LocalTime(now.hour, now.minute),
        today: LocalDate(now.year, now.month, now.day),
        findings: findings?.call() ?? const [],
      );
    } catch (e) {
      _log('digest: tick failed error=${e.runtimeType}');
      return null;
    }
  }

  void dispose() {
    _t?.cancel();
    _t = null;
  }
}
