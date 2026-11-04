import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/sky_bake.dart';

/// Every screen pixel of calm (and slightly rippled) water must reflect a
/// baked texel, not the fill colour. Option B's 60 degree pitch reflects the
/// zenith region behind the camera at the bottom of the screen; with only
/// +-100 degrees of azimuth baked that showed as a dark wedge.
void main() {
  const ew = 512, eh = 256;
  final cam = bakeCamera(const SkyBakeConfig(equirectWidth: ew, focal: 60), 0.7);
  final mesh = equirectMesh(cam, 0.7, ew, eh)!;
  final pos = mesh.positions, idx = mesh.indices;
  bool inTriangle(double px, double py, int a, int b, int c) {
    double cross(int p, int q) =>
        (pos[2 * q] - pos[2 * p]) * (py - pos[2 * p + 1]) -
        (pos[2 * q + 1] - pos[2 * p + 1]) * (px - pos[2 * p]);
    final d1 = cross(a, b), d2 = cross(b, c), d3 = cross(c, a);
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
  }

  bool covered(double x, double y, double z) {
    final l = math.sqrt(x * x + y * y + z * z);
    // Half a texel in from the wrap seam, which two edge quads share.
    final u = ((0.5 + math.atan2(x, z) / (2 * math.pi)) % 1.0).clamp(0.5 / ew, 1 - 0.5 / ew);
    final v = 0.5 - math.asin(math.max(y / l, 0.01)) / math.pi;
    final px = u * ew, py = v * eh;
    for (var k = 0; k < idx.length; k += 3) {
      if (inTriangle(px, py, idx[k], idx[k + 1], idx[k + 2])) return true;
    }
    return false;
  }

  for (final o in [ReflectionOptics.analytic, ReflectionOptics.gpu]) {
    test('reflections stay inside the bake (pitch ${o.pitchRad.toStringAsFixed(2)})', () {
      const aspect = 1080 / 2400;
      final sp = math.sin(o.pitchRad), cp = math.cos(o.pitchRad);
      final misses = <String>[];
      for (var a = 0; a <= 16; a++) {
        for (var b = 0; b <= 40; b++) {
          final sx = (a / 16 - 0.5) * aspect * o.fovScale;
          final sy = (b / 40 - 0.5) * o.fovScale;
          final dx = sx, dy = -sp - cp * sy, dz = cp - sp * sy;
          // Flat reflection, then the normal tilted up to ~0.08 rad.
          for (final (gx, gz) in [(0.0, 0.0), (0.08, 0.0), (-0.08, 0.0), (0.0, 0.08), (0.0, -0.08)]) {
            final nl = math.sqrt(1 + gx * gx + gz * gz);
            final nx = -gx / nl, ny = 1 / nl, nz = -gz / nl;
            final dn = dx * nx + dy * ny + dz * nz;
            if (!covered(dx - 2 * dn * nx, dy - 2 * dn * ny, dz - 2 * dn * nz)) {
              misses.add('($a,$b,$gx,$gz)');
            }
          }
        }
      }
      expect(misses, isEmpty);
    });
  }
}
