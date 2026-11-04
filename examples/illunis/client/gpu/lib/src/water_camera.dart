import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// Perspective camera above the water plane y = 0. Same model as option A
/// (shaders/water.frag): height [height], looking [pitch] radians below the
/// horizontal, screen height spanning 2 * atan(fovScale / 2).
///
/// Pitch is a parameter, not a constant, so the same surface can be viewed
/// from straight above (pi / 2, the phone as a puddle) down to a grazing
/// lake view; the simulated patch follows the visible footprint.
class WaterCamera {
  const WaterCamera({this.height = 1.0, this.pitch = 60 * math.pi / 180, this.fovScale = 1.2});

  final double height, pitch, fovScale;

  /// Unit view ray for screen uv (0..1, y down) at [aspect] = width / height.
  (double, double, double) viewRay(Offset uv, double aspect) {
    final sx = (uv.dx - 0.5) * aspect * fovScale;
    final sy = (uv.dy - 0.5) * fovScale;
    final sp = math.sin(pitch), cp = math.cos(pitch);
    final dx = sx, dy = -sp - cp * sy, dz = cp - sp * sy;
    final l = math.sqrt(dx * dx + dy * dy + dz * dz);
    return (dx / l, dy / l, dz / l);
  }

  /// Where the ray through [uv] meets the water, as world (x, z); null when
  /// the ray points at or above the horizon.
  Offset? planeHit(Offset uv, double aspect) {
    final (dx, dy, dz) = viewRay(uv, aspect);
    if (dy > -1e-3) return null;
    final t = height / -dy;
    return Offset(dx * t, dz * t);
  }

  /// World rectangle (left = x0, top = z0, right = x1, bottom = z1) that
  /// covers every visible water point closer than [farCap] (horizontal
  /// distance), plus [margin] of its size on each side for the sponge.
  Rect simDomain(double aspect, {double farCap = 6.0, double margin = 0.08}) {
    var x0 = double.infinity, x1 = -double.infinity;
    var z0 = double.infinity, z1 = -double.infinity;
    void add(double x, double z) {
      x0 = math.min(x0, x);
      x1 = math.max(x1, x);
      z0 = math.min(z0, z);
      z1 = math.max(z1, z);
    }

    const n = 32;
    for (var i = 0; i <= n; i++) {
      final f = i / n;
      for (final uv in [Offset(f, 0), Offset(f, 1), Offset(0, f), Offset(1, f)]) {
        final (dx, dy, dz) = viewRay(uv, aspect);
        final horiz = math.sqrt(dx * dx + dz * dz);
        // Distance along the ground to the hit, capped at farCap; rays that
        // miss the water count as reaching the cap.
        final ground = dy < -1e-3 ? math.min(height / -dy * horiz, farCap) : farCap;
        final s = horiz > 1e-9 ? ground / horiz : 0.0;
        add(dx * s, dz * s);
      }
    }
    final mx = (x1 - x0) * margin, mz = (z1 - z0) * margin;
    return Rect.fromLTRB(x0 - mx, z0 - mz, x1 + mx, z1 + mz);
  }
}

/// Sim texture size for [domain] with roughly square texels and about
/// [texelBudget] texels in total.
(int, int) simResolution(Rect domain, {int texelBudget = 786432, int maxSide = 2048}) {
  final aspect = domain.width / domain.height;
  var h = math.sqrt(texelBudget / aspect);
  var w = h * aspect;
  final over = math.max(w, h) / maxSide;
  if (over > 1) {
    w /= over;
    h /= over;
  }
  return (math.max(w.round(), 8), math.max(h.round(), 8));
}

/// World (x, z) to sim cell coordinates (texel indices, centres on integers).
Offset worldToCell(Offset world, Rect domain, int w, int h) => Offset(
      (world.dx - domain.left) / domain.width * w - 0.5,
      (world.dy - domain.top) / domain.height * h - 0.5,
    );
