import 'dart:math' as math;
import 'dart:typed_data';

/// Wave constants shared by the CPU reference ([stepHeightField]) and the GPU
/// pass (shaders/sim_step.frag, fed through SimInfo). The shader has no
/// numbers of its own, so the two cannot drift apart.
class WaveParams {
  const WaveParams({
    this.k = 0.25,
    this.damping = 0.996,
    this.spongeWidth = 24,
    this.spongeStrength = 0.08,
  });

  /// c^2 of the discrete wave equation (c = texels per step). The explicit
  /// 2D scheme is stable for k <= 0.5.
  final double k;

  /// Multiplier applied to every new height (1 = lossless).
  final double damping;

  /// Width in texels of the absorbing band along each edge.
  final double spongeWidth;

  /// Extra loss at the outermost texel (quadratic ramp inwards).
  final double spongeStrength;

  static const maxStableK = 0.5;

  /// Throws if the scheme would blow up or gain energy.
  void validate() {
    if (!(k > 0 && k <= maxStableK)) {
      throw ArgumentError.value(k, 'k', 'must be in (0, $maxStableK]');
    }
    if (!(damping > 0 && damping <= 1)) {
      throw ArgumentError.value(damping, 'damping', 'must be in (0, 1]');
    }
    if (!(spongeStrength >= 0 && spongeStrength < 1)) {
      throw ArgumentError.value(spongeStrength, 'spongeStrength', 'must be in [0, 1)');
    }
  }
}

/// A raised-cosine impulse added during one step. [x], [y] are texel indices
/// (cell centres are integers), [radius] in texels.
class Drop {
  const Drop(this.x, this.y, this.radius, this.strength);
  final double x, y, radius, strength;

  @override
  String toString() => 'Drop($x, $y, r=$radius, s=$strength)';
}

/// Maximum drops per step; matches `drops[4]` in sim_step.frag.
const maxDropsPerStep = 4;

/// One simulation state: heights now and one step ago, row-major
/// (index = y * width + x).
class HeightField {
  HeightField(this.width, this.height)
      : now = Float32List(width * height),
        prev = Float32List(width * height) {
    if (width < 3 || height < 3) {
      throw ArgumentError('heightfield must be at least 3x3');
    }
  }

  HeightField._(this.width, this.height, this.now, this.prev);

  final int width, height;
  final Float32List now, prev;

  double at(int x, int y) => now[y * width + x];
}

/// Pure heightfield step: returns the next state, leaving [s] unchanged.
/// Mirrors shaders/sim_step.frag exactly (clamped neighbours, sponge,
/// damping, then drops), so a GPU frame can be checked against it.
/// The new previous heights are the old current heights plus any drops.
HeightField stepHeightField(HeightField s, WaveParams p, [List<Drop> drops = const []]) {
  p.validate();
  if (drops.length > maxDropsPerStep) {
    throw ArgumentError('at most $maxDropsPerStep drops per step');
  }
  final w = s.width, h = s.height;
  final cur = s.now, old = s.prev;
  final next = Float32List(w * h), newPrev = Float32List(w * h);
  final sw = math.max(p.spongeWidth, 1.0);
  for (var y = 0; y < h; y++) {
    final ym = y == 0 ? 0 : y - 1, yp = y == h - 1 ? y : y + 1;
    for (var x = 0; x < w; x++) {
      final xm = x == 0 ? 0 : x - 1, xp = x == w - 1 ? x : x + 1;
      final i = y * w + x;
      final c = cur[i];
      final sum = cur[y * w + xp] + cur[y * w + xm] + cur[yp * w + x] + cur[ym * w + x];
      var n = 2 * c - old[i] + p.k * (sum - 4 * c);
      final edge = math.min(math.min(x, w - 1 - x), math.min(y, h - 1 - y)).toDouble();
      final sp = (1 - edge / sw).clamp(0.0, 1.0);
      n *= p.damping * (1 - p.spongeStrength * sp * sp);
      var bump = 0.0;
      for (final d in drops) {
        if (d.strength == 0) continue;
        final dx = x - d.x, dy = y - d.y;
        final r = math.sqrt(dx * dx + dy * dy);
        if (r < d.radius) bump += d.strength * 0.5 * (1 + math.cos(math.pi * r / d.radius));
      }
      next[i] = n + bump;
      // A drop displaces the surface without giving it velocity: the bump
      // goes into both channels, so no mass keeps flowing in afterwards.
      newPrev[i] = c + bump;
    }
  }
  return HeightField._(w, h, next, newPrev);
}

/// Discrete wave energy: kinetic (h - prev)^2 plus k * potential (sum of
/// squared forward differences). Constant for an undamped interior wave up
/// to the scheme's O(k) wobble; decays with damping and the sponge.
double waveEnergy(HeightField s, WaveParams p) {
  final w = s.width, h = s.height;
  var kin = 0.0, pot = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final v = s.now[i] - s.prev[i];
      kin += v * v;
      if (x + 1 < w) {
        final g = s.now[i + 1] - s.now[i];
        pot += g * g;
      }
      if (y + 1 < h) {
        final g = s.now[i + w] - s.now[i];
        pot += g * g;
      }
    }
  }
  return kin + p.k * pot;
}

/// Largest absolute height.
double maxAbsHeight(HeightField s) {
  var m = 0.0;
  for (final v in s.now) {
    final a = v.abs();
    if (a > m) m = a;
  }
  return m;
}
