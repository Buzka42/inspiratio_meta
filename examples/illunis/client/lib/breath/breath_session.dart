/// A guided session as a pure state machine (build plan B7, research
/// section 6). No timers, no clock: the view calls [BreathSession.advance]
/// with elapsed seconds and reads the state back. That keeps timing,
/// pause, stop and cues testable without waiting.
///
/// - Count-in: [Technique.countInCycles] cycles of the phases, shown as
///   text, before the session timer starts.
/// - Phases loop from pacing.phases. Cues fire once each when the session
///   timer reaches `at_s`.
/// - Pause holds the phase position and the timer; resume carries on.
/// - Stop ends at once with the end copy. Reaching `duration_s` ends too.
/// - Holds follow the research hold rules: an empty-lung hold is never
///   played, and a basic technique's hold is at most [maxBasicHoldS].
library;

import 'technique.dart';

/// Longest hold in the default (basic) library, research 6.1.
const maxBasicHoldS = 4.0;

enum BreathStage { countIn, running, ended }

enum BreathEnd { completed, stopped }

/// The phases a session plays: hold_empty removed, basic holds capped.
List<BreathPhase> safePhases(Technique t) {
  final p = t.pacing;
  if (p == null) return const [];
  return [
    for (final ph in p.phases)
      if (ph.kind != BreathPhaseKind.holdEmpty)
        ph.kind == BreathPhaseKind.hold && t.isBasic && ph.seconds > maxBasicHoldS
            ? const BreathPhase(BreathPhaseKind.hold, maxBasicHoldS)
            : ph,
  ];
}

class BreathSession {
  /// Throws [ArgumentError] for a technique with no playable timing.
  BreathSession(this.technique) : phases = safePhases(technique) {
    if (!technique.playable || phases.isEmpty) {
      throw ArgumentError.value(technique.id, 'technique', 'not playable');
    }
    cycleS = phases.fold(0.0, (a, p) => a + p.seconds);
    countInS = cycleS * technique.countInCycles;
    _levels = _targetLevels(phases);
  }

  final Technique technique;
  final List<BreathPhase> phases;
  late final double cycleS;
  late final double countInS;
  late final List<double> _levels;

  double _t = 0; // seconds since the count-in began, paused time excluded
  bool _paused = false;
  BreathEnd? _end;
  int _nextCue = 0;
  final _fired = <Cue>[];

  bool get paused => _paused;
  BreathEnd? get end => _end;

  BreathStage get stage => _end != null
      ? BreathStage.ended
      : _t < countInS
          ? BreathStage.countIn
          : BreathStage.running;

  /// Seconds on the session timer (0 during the count-in).
  double get elapsedS => (_t - countInS).clamp(0.0, technique.durationS.toDouble());

  double get remainingS => technique.durationS - elapsedS;

  /// 1, 2 or 3 during the count-in, else null.
  int? get countInCycle => stage == BreathStage.countIn ? (_t / cycleS).floor() + 1 : null;

  int get _phaseIndex => _phaseAt(_t).$1;

  BreathPhase get phase => phases[_phaseIndex];

  /// 0 at the start of the current phase, 1 at its end.
  double get phaseProgress => _phaseAt(_t).$2 / phase.seconds;

  double get phaseRemainingS => phase.seconds - _phaseAt(_t).$2;

  /// How full the visual is, 0 (empty) to 1 (full): it grows on an inhale,
  /// shrinks on an exhale and stays still during a hold.
  double get level {
    final i = _phaseIndex;
    final from = _levels[(i - 1 + phases.length) % phases.length];
    final to = _levels[i];
    final x = phaseProgress.clamp(0.0, 1.0);
    final eased = x * x * (3 - 2 * x); // smoothstep, no sudden jumps
    return from + (to - from) * eased;
  }

  /// Cues fired so far, in order.
  List<Cue> get firedCues => List.unmodifiable(_fired);

  /// The cue on screen: the latest one fired.
  Cue? get currentCue => _fired.isEmpty ? null : _fired.last;

  String get endText => technique.copy.end;

  /// Moves time on by [dt] seconds. Returns the cues that fired during it
  /// (each fires once). Does nothing while paused or after the end.
  List<Cue> advance(double dt) {
    if (_paused || _end != null || dt <= 0) return const [];
    _t += dt;
    final out = <Cue>[];
    final cues = technique.cues;
    while (_nextCue < cues.length && cues[_nextCue].atS < technique.durationS &&
        _t >= countInS + cues[_nextCue].atS) {
      out.add(cues[_nextCue++]);
    }
    _fired.addAll(out);
    if (_t >= countInS + technique.durationS) {
      _t = countInS + technique.durationS;
      _end = BreathEnd.completed;
    }
    return out;
  }

  void pause() {
    if (_end == null) _paused = true;
  }

  void resume() => _paused = false;

  void stop() {
    if (_end != null) return;
    _paused = false;
    _end = BreathEnd.stopped;
  }

  (int, double) _phaseAt(double t) {
    var x = t % cycleS;
    for (var i = 0; i < phases.length; i++) {
      if (x < phases[i].seconds) return (i, x);
      x -= phases[i].seconds;
    }
    return (phases.length - 1, phases.last.seconds);
  }
}

/// The level each phase ends at. An inhale followed by a top-up stops short
/// of full so the top-up has room; holds keep the level they start at.
List<double> _targetLevels(List<BreathPhase> phases) {
  final out = List<double>.filled(phases.length, 0);
  var last = 0.0;
  for (var i = 0; i < phases.length; i++) {
    final next = phases[(i + 1) % phases.length].kind;
    last = switch (phases[i].kind) {
      BreathPhaseKind.inhale => next == BreathPhaseKind.topUp ? 0.8 : 1.0,
      BreathPhaseKind.topUp => 1.0,
      BreathPhaseKind.exhale => 0.0,
      BreathPhaseKind.hold || BreathPhaseKind.holdEmpty => last,
    };
    out[i] = last;
  }
  // A leading hold takes the level the cycle ends at.
  for (var i = 0; i < phases.length && phases[i].kind.isHold; i++) {
    out[i] = out.last;
  }
  return out;
}
