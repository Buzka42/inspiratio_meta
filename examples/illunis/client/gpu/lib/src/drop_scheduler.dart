import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'heightfield.dart';

/// Decides which drops enter the simulation each step: a slow pulse under
/// the walker and sparse ambient drops whose rate rises with loudness.
/// Seeded, so a run is reproducible. Sizes are in world units and converted
/// with [cellWorld] (world units per texel).
class DropScheduler {
  DropScheduler({
    int seed = 11,
    this.walkerPeriod = 0.9,
    this.walkerRadius = 0.03,
    this.walkerStrength = 0.35,
    this.ambientRate = 0.4,
    this.loudRate = 5.0,
    this.ambientRadius = 0.014,
    this.ambientStrength = 0.18,
  }) : _rnd = math.Random(seed);

  final math.Random _rnd;
  final double walkerPeriod, walkerRadius, walkerStrength;
  final double ambientRate, loudRate, ambientRadius, ambientStrength;
  double? _sinceWalker; // null: the first step on the water pulses at once
  double _ambientDebt = 0;

  /// Drops for one step of length [dt] seconds. [walkerCell] is the walker's
  /// sim cell (null when its ray misses the water), [loudness] 0..1,
  /// [w] x [h] the sim size. Never returns more than [maxDropsPerStep].
  List<Drop> next(double dt, Offset? walkerCell, double loudness, int w, int h, double cellWorld) {
    final loud = loudness.clamp(0.0, 1.0);
    final out = <Drop>[];
    final period = walkerPeriod / (1 + loud);
    final since = (_sinceWalker ?? period) + dt;
    _sinceWalker = since;
    if (walkerCell != null && since >= period - 1e-9) {
      // Keep the phase so pulses stay on the period; never bank more than one.
      _sinceWalker = math.min(since - period, period);
      out.add(Drop(walkerCell.dx, walkerCell.dy, walkerRadius / cellWorld,
          -walkerStrength * (1 + 1.5 * loud)));
    }
    _ambientDebt += dt * (ambientRate + loudRate * loud);
    while (_ambientDebt >= 1 && out.length < maxDropsPerStep) {
      _ambientDebt -= 1;
      final sign = _rnd.nextBool() ? 1.0 : -1.0;
      out.add(Drop(
        w * (0.1 + 0.8 * _rnd.nextDouble()),
        h * (0.1 + 0.8 * _rnd.nextDouble()),
        ambientRadius / cellWorld * (0.7 + 0.6 * _rnd.nextDouble()),
        sign * ambientStrength * (0.5 + 0.5 * _rnd.nextDouble()) * (1 + loud),
      ));
    }
    // Drops beyond the per-step cap carry over instead of piling up.
    if (_ambientDebt > maxDropsPerStep) _ambientDebt = maxDropsPerStep.toDouble();
    return out;
  }
}
