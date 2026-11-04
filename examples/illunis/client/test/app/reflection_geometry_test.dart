import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/reflection_geometry.dart';

/// Forward model of the water shaders' viewRay (water.frag), for checking
/// the inverse in [reflectedScreenPoint].
(double, double, double) viewRay(Offset uv, double aspect, ReflectionOptics o) {
  final sx = (uv.dx - 0.5) * aspect * o.fovScale;
  final sy = (uv.dy - 0.5) * o.fovScale;
  final sp = math.sin(o.pitchRad), cp = math.cos(o.pitchRad);
  final x = sx, y = -sp - cp * sy, z = cp - sp * sy;
  final l = math.sqrt(x * x + y * y + z * z);
  return (x / l, y / l, z / l);
}

void main() {
  const size = Size(360, 800);
  const az = 2.1;

  test('equirect lookup and its inverse agree', () {
    for (final (u, v) in [(0.5, 0.25), (0.31, 0.1), (0.7, 0.45), (0.52, 0.02)]) {
      final d = equirectDir(u, v, az);
      expect(d.length, closeTo(1, 1e-9));
      final (u2, v2) = equirectUv(d, az);
      expect(u2, closeTo(u, 1e-9));
      expect(v2, closeTo(v, 1e-9));
    }
    // u 0.5 is the camera's bearing; v 0 the zenith.
    expect(equirectDir(0.5, 0.5, az).azimuth, closeTo(az, 1e-9));
    expect(equirectDir(0.3, 0, az).y, closeTo(1, 1e-9));
  });

  for (final o in [ReflectionOptics.analytic, ReflectionOptics.gpu]) {
    test('calm reflection lands where the shader ray mirrors it (pitch ${o.pitchRad})', () {
      // A body straight ahead at the pitch angle reflects at the screen centre.
      final ahead = waterToWorld(0, math.sin(o.pitchRad), math.cos(o.pitchRad), az);
      final c = reflectedScreenPoint(ahead, az, size, o)!;
      expect(c.dx, closeTo(180, 1e-6));
      expect(c.dy, closeTo(400, 1e-6));

      // Any screen point: mirror its view ray into the sky and back.
      for (final uv in [const Offset(0.2, 0.3), const Offset(0.8, 0.9), const Offset(0.5, 0.1)]) {
        final (x, y, z) = viewRay(uv, size.width / size.height, o);
        final sky = waterToWorld(x, -y, z, az);
        final p = reflectedScreenPoint(sky, az, size, o)!;
        expect(p.dx, closeTo(uv.dx * size.width, 1e-6));
        expect(p.dy, closeTo(uv.dy * size.height, 1e-6));
      }
    });
  }

  test('a body below the horizon has no reflection', () {
    final below = waterToWorld(0, -0.2, 0.98, az);
    expect(reflectedScreenPoint(below, az, size, ReflectionOptics.analytic), isNull);
  });

  test('reflected radius grows with the angular radius', () {
    final d = waterToWorld(0, 0.7, 0.7, az).normalized;
    final r1 = reflectedRadius(d, az, moonAngularRadius(1), size, ReflectionOptics.analytic);
    final r4 = reflectedRadius(d, az, moonAngularRadius(4), size, ReflectionOptics.analytic);
    expect(r1, greaterThan(1));
    expect(r4, closeTo(4 * r1, 1e-9));
  });
}
