import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

HeightField run(HeightField s, WaveParams p, int steps) {
  for (var i = 0; i < steps; i++) {
    s = stepHeightField(s, p);
  }
  return s;
}

void main() {
  const lossless = WaveParams(damping: 1, spongeStrength: 0);

  test('a single drop spreads into a symmetric ring', () {
    const n = 65, c = 32;
    var s = stepHeightField(HeightField(n, n), lossless, const [Drop(32, 32, 3, 1)]);
    final peak = s.at(c, c);
    expect(peak, closeTo(1.0, 1e-6));
    expect(s.prev[c * n + c], closeTo(1.0, 1e-6)); // displaced, not launched
    s = run(s, lossless, 30);
    // The centre has fallen well below the impulse; energy moved outwards.
    expect(s.at(c, c).abs(), lessThan(0.5 * peak));
    // Something has arrived ~10 texels out (wave speed 0.5 texel/step).
    var ring = 0.0;
    for (var d = 8; d <= 14; d++) {
      ring = math.max(ring, s.at(c + d, c).abs());
    }
    expect(ring, greaterThan(1e-3));
    // Nothing yet at 28 texels (the front travels about 15 texels in 30 steps).
    expect(s.at(c + 28, c).abs(), lessThan(1e-4));
    // Four-fold symmetry of a centred drop.
    for (var d = 1; d < 20; d++) {
      final e = s.at(c + d, c);
      expect(s.at(c - d, c), closeTo(e, 1e-5));
      expect(s.at(c, c + d), closeTo(e, 1e-5));
      expect(s.at(c, c - d), closeTo(e, 1e-5));
    }
  });

  test('lossless interior: energy is held (within the scheme wobble)', () {
    var s = stepHeightField(HeightField(96, 96), lossless, const [Drop(48, 48, 4, 0.5)]);
    s = run(s, lossless, 5);
    final e0 = waveEnergy(s, lossless);
    s = run(s, lossless, 60); // before the front reaches the walls
    final e1 = waveEnergy(s, lossless);
    expect(e1, closeTo(e0, 0.2 * e0));
  });

  test('damping and the sponge drain the energy', () {
    const p = WaveParams();
    var s = stepHeightField(HeightField(96, 96), p, const [Drop(48, 48, 4, 0.5)]);
    s = run(s, p, 5);
    final early = waveEnergy(s, p);
    s = run(s, p, 1500);
    expect(waveEnergy(s, p), lessThan(0.01 * early));
  });

  test('energy never blows up: noise for 4000 steps at k = 0.45, no damping', () {
    const p = WaveParams(k: 0.45, damping: 1, spongeStrength: 0);
    final rnd = math.Random(3);
    final s0 = HeightField(40, 40);
    for (var i = 0; i < s0.now.length; i++) {
      s0.now[i] = rnd.nextDouble() * 2 - 1;
      s0.prev[i] = s0.now[i];
    }
    var s = s0;
    final e0 = waveEnergy(stepHeightField(s, p), p);
    var worst = 0.0;
    for (var i = 0; i < 4000; i++) {
      s = stepHeightField(s, p);
      if (i % 50 == 0) worst = math.max(worst, waveEnergy(s, p));
    }
    expect(maxAbsHeight(s).isFinite, isTrue);
    expect(maxAbsHeight(s), lessThan(10));
    expect(worst, lessThan(3 * e0));
  });

  test('defaults: many drops over a long run stay bounded', () {
    const p = WaveParams();
    final sched = DropScheduler(seed: 5);
    var s = HeightField(80, 120);
    var peak = 0.0;
    for (var i = 0; i < 3000; i++) {
      s = stepHeightField(s, p, sched.next(1 / 120, const Offset(40, 60), 1.0, 80, 120, 0.002));
      peak = math.max(peak, maxAbsHeight(s));
    }
    expect(peak.isFinite, isTrue);
    expect(peak, lessThan(5));
  });

  test('the step is pure: inputs are not changed', () {
    final s = HeightField(8, 8);
    s.now[27] = 1;
    final before = Float32List.fromList(s.now), beforePrev = Float32List.fromList(s.prev);
    stepHeightField(s, const WaveParams(), const [Drop(2, 2, 2, 1)]);
    expect(s.now, before);
    expect(s.prev, beforePrev);
    expect(stepHeightField(s, const WaveParams()).prev, before); // new "previous" = old "now"
  });

  test('a zero-strength drop is ignored', () {
    final a = stepHeightField(HeightField(9, 9), lossless, const [Drop(4, 4, 3, 0)]);
    expect(maxAbsHeight(a), 0);
  });

  test('unstable or invalid parameters are refused', () {
    expect(() => stepHeightField(HeightField(5, 5), const WaveParams(k: 0.6)), throwsArgumentError);
    expect(() => stepHeightField(HeightField(5, 5), const WaveParams(damping: 1.01)), throwsArgumentError);
    expect(
        () => stepHeightField(HeightField(5, 5), const WaveParams(),
            List.filled(maxDropsPerStep + 1, const Drop(1, 1, 1, 1))),
        throwsArgumentError);
    expect(() => HeightField(2, 5), throwsArgumentError);
  });
}
