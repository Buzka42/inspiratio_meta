import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../moon_render/moon_controller.dart';
import '../moon_render/moon_renderer.dart';
import '../moon_render/moon_shading.dart';
import '../sky/celestial_math.dart';

/// Tangent frame of the sky at the moon: [right] is horizontal, [up] points
/// toward the zenith. A disc drawn upright in this frame is upright in the sky.
class MoonFrame {
  factory MoonFrame(Vec3 moonDir, {Vec3? fallbackForward}) {
    final m = moonDir.normalized;
    var r = m.cross(Vec3.up);
    if (r.length < 1e-6) r = (fallbackForward ?? const Vec3(0, 0, -1)).cross(Vec3.up);
    r = r.normalized;
    return MoonFrame._(m, r, r.cross(m).normalized);
  }
  MoonFrame._(this.dir, this.right, this.up);

  final Vec3 dir, right, up;

  /// Screen angle (y down) of the sun's direction across the disc.
  double sunAngle(Vec3 sunDir) => math.atan2(-sunDir.dot(up), sunDir.dot(right));
}

/// Draws the textured moon disc of [radius] at [centre], lit from screen
/// angle [sunAngle] with lit fraction [illumination], shaded by the same
/// Lommel-Seeliger model as sky.frag, with a faint halo. The dark side keeps
/// a trace of earthshine at night and fades into the sky by day ([dayness]).
/// Uses [moon]'s default map (and loaded tiles); its own view zoom must be 1.
void paintMoonDisc(
  Canvas canvas, {
  required MoonController moon,
  required Offset centre,
  required double radius,
  required double sunAngle,
  required double illumination,
  required double dayness,
}) {
  if (radius <= 0.5) return;
  final box = 2 * radius / moon.fitFraction;
  final disc = Rect.fromCircle(center: centre, radius: radius);
  // Soft aureole, fading to zero inside the picture's clear border.
  final halo = moonHaloPaint(
      centre: centre,
      radius: radius,
      outerRadius: box / 2 - 1,
      illumination: illumination,
      dayness: dayness);
  if (halo != null) canvas.drawCircle(centre, box / 2 - 1, halo);
  canvas.saveLayer(disc.inflate(2), Paint());
  canvas.save();
  canvas.translate(centre.dx - box / 2, centre.dy - box / 2);
  MoonPainter(moon, light: MoonLight.fromPhase(sunAngle, illumination), dayness: dayness)
      .paint(canvas, Size(box, box));
  canvas.restore();
  canvas.restore();
}

/// Outline of the unlit part of a disc (the shading itself is
/// MoonPainter's Lommel-Seeliger, whose terminator is this same curve):
/// the lit side is the half facing [sunAngle]
/// plus (gibbous) or minus (crescent) the terminator half-ellipse.
Path moonDarkSide(Offset centre, double radius, double sunAngle, double illumination) {
  final k = illumination.clamp(0.0, 1.0);
  final c = Offset.zero;
  final circle = Rect.fromCircle(center: c, radius: radius);
  final half = Path()
    ..addArc(circle, -math.pi / 2, math.pi)
    ..close();
  final ellipse = Path()
    ..addOval(Rect.fromCenter(center: c, width: 2 * radius * (2 * k - 1).abs(), height: 2 * radius));
  final lit = Path.combine(k >= 0.5 ? PathOperation.union : PathOperation.difference, half, ellipse);
  final dark = Path.combine(PathOperation.difference, Path()..addOval(circle), lit);
  final m = Matrix4Rotation.about(centre, sunAngle);
  return dark.transform(m);
}

/// Column-major 4x4 for a rotation by [angle] about [centre].
abstract final class Matrix4Rotation {
  static Float64List about(Offset centre, double angle) {
    final c = math.cos(angle), s = math.sin(angle);
    return Float64List.fromList([
      c, s, 0, 0, //
      -s, c, 0, 0, //
      0, 0, 1, 0, //
      centre.dx, centre.dy, 0, 1, //
    ]);
  }
}
