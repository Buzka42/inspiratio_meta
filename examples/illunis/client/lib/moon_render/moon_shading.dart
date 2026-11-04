import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Direction of the sun as seen from the moon, in the disc's screen frame:
/// x right, y down, z toward the viewer. One model for every moon drawing:
/// the same Lommel-Seeliger surface sky.frag uses, so the phase, the
/// terminator and the limb match the sky.
class MoonLight {
  const MoonLight(this.x, this.y, this.z);

  /// From the sun's screen angle across the disc (y down, as
  /// MoonFrame.sunAngle) and the lit fraction (illumination = (1 + cos a) / 2
  /// for phase angle a).
  factory MoonLight.fromPhase(double sunAngle, double illumination) {
    final cosA = (2 * illumination.clamp(0.0, 1.0) - 1).toDouble();
    final sinA = math.sqrt(math.max(0.0, 1 - cosA * cosA));
    return MoonLight(sinA * math.cos(sunAngle), sinA * math.sin(sunAngle), cosA);
  }

  /// From world directions: the moon's (observer to moon), the sun's, and
  /// the disc's [right] and [up] tangent axes (MoonFrame).
  factory MoonLight.fromDirections(
    (double, double, double) moonDir,
    (double, double, double) sunDir,
    (double, double, double) right,
    (double, double, double) up,
  ) {
    double dot((double, double, double) a, (double, double, double) b) =>
        a.$1 * b.$1 + a.$2 * b.$2 + a.$3 * b.$3;
    final x = dot(sunDir, right), y = -dot(sunDir, up), z = -dot(sunDir, moonDir);
    final len = math.sqrt(x * x + y * y + z * z);
    return len < 1e-12 ? const MoonLight(0, 0, 1) : MoonLight(x / len, y / len, z / len);
  }

  final double x, y, z;

  /// Lit fraction of the disc this light gives.
  double get illumination => (1 + z) / 2;

  @override
  bool operator ==(Object other) =>
      other is MoonLight && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

/// Linear surface factor at full moon centre, below 1 so the brightest
/// highlands of the map stay off pure white over a dark sky.
const moonPeak = 0.94;

/// Linear earthshine left on the night side (the old mask kept about 6
/// percent of the sRGB map, roughly this in linear light).
const moonEarthshine = 0.004;

/// Linear brightness factor of the surface at disc offset ([u], [v]) in
/// radii (v down). Lommel-Seeliger ci / (ci + ce), doubled so a full moon
/// is flat at 1, then a soft shoulder scaled by [moonPeak]: a crescent's
/// bright limb rolls off instead of clipping, plus [moonEarthshine].
double moonSurfaceFactor(double u, double v, MoonLight l) {
  var d = u * u + v * v;
  var nu = u, nv = v;
  if (d > 1) {
    final s = 1 / math.sqrt(d);
    nu *= s;
    nv *= s;
    d = 1;
  }
  final ce = math.sqrt(math.max(0.0, 1 - d));
  final ci = nu * l.x + nv * l.y + ce * l.z;
  final ls = ci <= 0 || ci + ce < 1e-6 ? 0.0 : ci / (ci + ce);
  return moonEarthshine + moonPeak * _shoulder(2 * ls);
}

/// Identity to 0.8, then an exponential shoulder toward 1.
double _shoulder(double x) {
  const k = 0.8, w = 1 - k;
  return x <= k ? x : k + w * (1 - math.exp(-(x - k) / w));
}

/// Grid of the shading mesh across the disc's bounding square.
const moonShadeGrid = 40;

/// A colour-only mesh over the disc of [radius] at [centre]. Drawn srcOver
/// on the opaque map inside the disc clip, black with alpha 1 - f (f in
/// sRGB) multiplies the map by the linear [moonSurfaceFactor]. With
/// [dayness] > 0 it also returns a dstOut mesh that fades the night side
/// into the sky by day (needs the disc in its own layer).
({ui.Vertices shade, ui.Vertices? dayFade}) buildMoonShading({
  required ui.Offset centre,
  required double radius,
  required MoonLight light,
  double dayness = 0,
  int grid = moonShadeGrid,
}) {
  final stride = grid + 1;
  final n = stride * stride;
  final pos = Float32List(n * 2);
  final shade = Int32List(n);
  final fade = dayness > 0 ? Int32List(n) : null;
  final day = dayness.clamp(0.0, 1.0);
  for (var j = 0; j <= grid; j++) {
    final v = -1 + 2 * j / grid;
    for (var i = 0; i <= grid; i++) {
      final u = -1 + 2 * i / grid;
      final k = j * stride + i;
      pos[2 * k] = centre.dx + u * radius;
      pos[2 * k + 1] = centre.dy + v * radius;
      final f = moonSurfaceFactor(u, v, light);
      final srgb = math.pow(f, 1 / 2.2).toDouble();
      shade[k] = _black(1 - srgb);
      if (fade != null) {
        final lit = _smooth(0.0, 0.08, f - moonEarthshine);
        fade[k] = _black(0.9 * day * (1 - lit));
      }
    }
  }
  final idx = Uint16List(grid * grid * 6);
  var p = 0;
  for (var j = 0; j < grid; j++) {
    for (var i = 0; i < grid; i++) {
      final a = j * stride + i, b = a + 1, c = a + stride, d = c + 1;
      idx
        ..[p++] = a
        ..[p++] = b
        ..[p++] = c
        ..[p++] = b
        ..[p++] = d
        ..[p++] = c;
    }
  }
  ui.Vertices mesh(Int32List colors) => ui.Vertices.raw(
        ui.VertexMode.triangles,
        pos,
        colors: colors,
        indices: idx,
      );
  return (shade: mesh(shade), dayFade: fade == null ? null : mesh(fade));
}

/// Peak alpha of the halo at the limb of a full moon at night.
const moonHaloAlpha = 0.10;

/// A soft aureole from the limb ([radius]) out to [outerRadius], falling as
/// 1 / x^2 and reaching zero at the outer edge, so a picture cropped there
/// shows no ring. Null when it would be invisible.
ui.Paint? moonHaloPaint({
  required ui.Offset centre,
  required double radius,
  required double outerRadius,
  required double illumination,
  required double dayness,
}) {
  final a = moonHaloAlpha *
      (0.25 + 0.75 * illumination.clamp(0.0, 1.0)) *
      (1 - dayness.clamp(0.0, 1.0));
  if (a <= 0.002 || outerRadius <= radius + 1) return null;
  final xe = outerRadius / radius;
  final floor = 1 / (xe * xe);
  const steps = 6;
  final colors = <ui.Color>[], stops = <double>[];
  final r0 = radius / outerRadius;
  for (var s = 0; s <= steps; s++) {
    final t = s / steps;
    final x = 1 + (xe - 1) * t;
    final f = ((1 / (x * x)) - floor) / (1 - floor);
    colors.add(ui.Color.fromRGBO(158, 173, 204, a * f));
    stops.add(r0 + (1 - r0) * t);
  }
  return ui.Paint()
    ..shader = ui.Gradient.radial(centre, outerRadius, [
      colors.first,
      ...colors,
    ], [
      0,
      ...stops,
    ]);
}

int _black(double alpha) => ((alpha.clamp(0.0, 1.0) * 255).round() & 0xFF) << 24;

double _smooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}
