/// Geometry shared by the sky bake, the water shaders and the moon hit test.
/// Pure Dart; mirrors the camera and sky lookup of shaders/water.frag
/// (option A) and gpu/shaders/water_surface.frag (option B).
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../sky/celestial_math.dart';
import '../sky/celestial_scene.dart';
import '../sky/sky_shader.dart';
import '../sky/star_field.dart' show driftedDirection;

/// The water camera a port draws with: pitch below the horizontal and the
/// screen-height field scale (screen height spans 2 * atan(fovScale / 2)).
class ReflectionOptics {
  const ReflectionOptics(this.pitchRad, {this.fovScale = 1.2});

  final double pitchRad;
  final double fovScale;

  /// Option A: the PITCH constant in shaders/water.frag.
  static const analytic = ReflectionOptics(0.785398);

  /// Option B: WaterCamera's default pitch (60 degrees).
  static const gpu = ReflectionOptics(60 * math.pi / 180);

  @override
  bool operator ==(Object other) =>
      other is ReflectionOptics && other.pitchRad == pitchRad && other.fovScale == fovScale;

  @override
  int get hashCode => Object.hash(pitchRad, fovScale);
}

/// Bearing both modes face: the moon while it is up (so its reflection sits
/// straight ahead), otherwise the scene's own tracking bearing. [driftRad]
/// is the sidereal turn since the scene was resolved (see
/// siderealDriftRad), so the camera follows the moon between resolves.
double viewAzimuth(ResolvedScene scene, {double driftRad = 0}) {
  final moon = driftedDirection(scene.moonDir, scene.latitudeRad, driftRad);
  return moon.y > 0 ? moon.azimuth : scene.trackAzimuthRad;
}

/// Moon angular radius for a zoom factor (1 = the sky shader's own disc).
double moonAngularRadius(double zoom) => SkyShader.moonAngularRadius * zoom;

Vec3 _right(double az) => Vec3(math.cos(az), 0, math.sin(az));
Vec3 _forward(double az) => Vec3(math.sin(az), 0, -math.cos(az));

/// Water frame (x right, y up, z forward, camera facing [az]) to the sky's
/// horizontal frame (x east, y up, z south).
Vec3 waterToWorld(double x, double y, double z, double az) =>
    _right(az) * x + Vec3.up * y + _forward(az) * z;

/// Inverse of [waterToWorld].
(double, double, double) worldToWater(Vec3 w, double az) =>
    (w.dot(_right(az)), w.y, w.dot(_forward(az)));

/// World direction of an equirectangular texel, using the shaders' lookup:
/// u = 0.5 + atan(x, z) / 2pi, v = 0.5 - asin(y) / pi.
Vec3 equirectDir(double u, double v, double az) {
  final a = (u - 0.5) * 2 * math.pi;
  final e = (0.5 - v) * math.pi;
  return waterToWorld(math.sin(a) * math.cos(e), math.sin(e), math.cos(a) * math.cos(e), az);
}

/// Equirectangular (u, v) of a world direction for a camera facing [az].
(double, double) equirectUv(Vec3 world, double az) {
  final (x, y, z) = worldToWater(world.normalized, az);
  return (0.5 + math.atan2(x, z) / (2 * math.pi), 0.5 - math.asin(y.clamp(-1.0, 1.0)) / math.pi);
}

/// Where calm water shows the reflection of [world] (a sky direction), in
/// the coordinates of [size], or null when it falls off the screen or the
/// body is below the shader's horizon clamp.
Offset? reflectedScreenPoint(Vec3 world, double az, Size size, ReflectionOptics o) {
  final (mx, my, mz) = worldToWater(world.normalized, az);
  if (my <= 0.01) return null;
  // Flat water flips y: the view ray that sees the body points down.
  final dx = mx, dy = -my, dz = mz;
  final sp = math.sin(o.pitchRad), cp = math.cos(o.pitchRad);
  final cf = dy * -sp + dz * cp; // along the camera's forward
  if (cf <= 1e-3) return null;
  final cu = dy * cp + dz * sp; // along the camera's up
  final sx = dx / cf, sy = -cu / cf;
  final aspect = size.width / size.height;
  final p = Offset(
    (0.5 + sx / (aspect * o.fovScale)) * size.width,
    (0.5 + sy / o.fovScale) * size.height,
  );
  const pad = 0.25;
  final inside = p.dx > -size.width * pad &&
      p.dx < size.width * (1 + pad) &&
      p.dy > -size.height * pad &&
      p.dy < size.height * (1 + pad);
  return inside ? p : null;
}

/// Approximate on-screen radius of a reflected disc of angular radius [rho].
double reflectedRadius(Vec3 world, double az, double rho, Size size, ReflectionOptics o) {
  final (_, my, mz) = worldToWater(world.normalized, az);
  final sp = math.sin(o.pitchRad), cp = math.cos(o.pitchRad);
  final cf = math.max(-my * -sp + mz * cp, 0.05);
  // Perspective stretch off axis: sec^2 radially, sec tangentially.
  return rho * (size.height / o.fovScale) / math.pow(cf, 1.5);
}
