import 'dart:math' as math;
import 'dart:ui';

import 'celestial_math.dart';

/// Where the horizon sits, as a fraction of the view's height. The shell
/// lays the ground band out from the same number (re-exported by tokens).
const double kHorizonFraction = 0.56;

/// A stereographic camera standing on the ground, looking at the horizon.
///
/// Stereographic because it is conformal: the sun and moon stay round at
/// the edge of a wide frame, and the horizon — a great circle through the
/// forward direction — stays a straight line. The principal point sits on
/// the horizon at [horizonFraction] of the height, so most of the frame is
/// sky and the ground below is a matte field for figures.
///
/// The shader inverts exactly this mapping; keep the two in step.
class SkyCamera {
  SkyCamera({
    required this.size,
    required this.azimuthRad,
    this.horizonFraction = kHorizonFraction,
    this.topAltitudeDeg = 76,
  }) : principal = Offset(size.width / 2, size.height * horizonFraction),
       focal =
           (size.height * horizonFraction) /
           (2 * math.tan(topAltitudeDeg * degToRad / 2));

  final Size size;

  /// Compass bearing the camera faces, radians.
  final double azimuthRad;
  final double horizonFraction;

  /// Altitude that lands on the top edge above the principal point.
  final double topAltitudeDeg;

  final Offset principal;
  final double focal;

  Vec3 get forward => Vec3(math.sin(azimuthRad), 0, -math.cos(azimuthRad));
  Vec3 get right => Vec3(math.cos(azimuthRad), 0, math.sin(azimuthRad));

  /// Screen position of a world direction, or null when it is behind the
  /// camera far enough that the projection has no useful answer.
  Offset? project(Vec3 d) {
    final cz = d.dot(forward);
    final cx = d.dot(right);
    final cy = d.y;
    // r = 2 tan(θ/2) = 2 sinθ / (1 + cosθ)
    final denom = 1 + cz;
    if (denom < 0.08) return null;
    final k = 2 / denom;
    return Offset(principal.dx + cx * k * focal, principal.dy - cy * k * focal);
  }

  /// World direction through a screen point.
  Vec3 unproject(Offset p) {
    final qx = (p.dx - principal.dx) / focal;
    final qy = -(p.dy - principal.dy) / focal;
    final r2 = qx * qx + qy * qy;
    // Inverse of r = 2 tan(θ/2): cosθ = (4 − r²)/(4 + r²), sinθ = 4r/(4 + r²)
    final cz = (4 - r2) / (4 + r2);
    final s = 4 / (4 + r2);
    final cx = qx * s, cy = qy * s;
    final f = forward, rt = right;
    return Vec3(rt.x * cx + f.x * cz, cy, rt.z * cx + f.z * cz).normalized;
  }

  /// Pixels per radian at the principal point; angular sizes scale by this.
  double get pixelsPerRadian => focal;

  bool contains(Offset p) =>
      p.dx >= -1 &&
      p.dy >= -1 &&
      p.dx <= size.width + 1 &&
      p.dy <= size.height + 1;
}
