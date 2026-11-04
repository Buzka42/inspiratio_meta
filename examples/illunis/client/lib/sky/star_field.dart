import 'dart:math' as math;
import 'dart:ui';

import 'celestial_math.dart';
import 'celestial_scene.dart';
import 'sky_camera.dart';
import 'sky_shader.dart';
import 'star_catalog.dart';

/// One row of [kStarPack].
class CatalogStar {
  const CatalogStar({
    required this.index,
    required this.raRad,
    required this.decRad,
    required this.vMag,
    required this.bv,
  });

  final int index;
  final double raRad;
  final double decRad;
  final double vMag;
  final double bv;
}

CatalogStar catalogStarAt(int i) {
  final p = kStarPack;
  final o = i * 4;
  return CatalogStar(
    index: i,
    raRad: p[o],
    decRad: p[o + 1],
    vMag: p[o + 2],
    bv: p[o + 3],
  );
}

CatalogStar? catalogStarByName(String name) {
  final i = kStarNameIndex[name];
  if (i == null) return null;
  return catalogStarAt(i);
}

/// Horizontal direction of a catalog star at the scene's sidereal time.
Vec3 catalogStarDirection(CatalogStar star, double siderealRad, double latRad) {
  return horizontalDirection(
    star.decRad,
    wrapAngle(siderealRad - star.raRad),
    latRad,
  );
}

/// Earth's turn against the stars: one sidereal day (23 h 56 m 4.1 s) per
/// revolution, about 15.04 degrees an hour. Radians per wall-clock second.
const siderealRadPerSecond = 2 * math.pi * 1.00273790935 / 86400;

/// Sidereal angle the sky turns through in [elapsed] wall-clock time. A
/// caller adds it to a scene resolved [elapsed] ago instead of resolving
/// the scene (and regenerating the field) every frame.
double siderealDriftRad(Duration elapsed) =>
    elapsed.inMicroseconds / 1e6 * siderealRadPerSecond;

/// The north celestial pole in the horizontal frame of an observer at
/// [latRad] (a southern observer gets it below the horizon).
Vec3 celestialPole(double latRad) =>
    Vec3(0, math.sin(latRad), -math.cos(latRad));

/// [dir] carried about the celestial pole by [driftRad] of sidereal time,
/// east to west. Exact for stars; for the moon it leaves out its own
/// eastward motion (about 0.5 degrees an hour), which the next resolve
/// adds back.
Vec3 driftedDirection(Vec3 dir, double latRad, double driftRad) =>
    driftRad == 0 ? dir : dir.rotated(celestialPole(latRad), -driftRad);

/// Same twilight ramp as the old shader field: nothing by civil dusk,
/// full by astronomical night.
double catalogStarVisibility(double sunAltDeg) =>
    smoothstep(-5, -15, sunAltDeg);

// Logarithmic alpha bins retain faint-star magnitude, air mass, glare and
// twinkle while bounding the faint field to 48 Canvas calls.
const _bins = 24;
final _points = List.generate(_bins * 2, (_) => <Offset>[]);
// Catalog-only work is fixed for the lifetime of the bundled J2000 table.
final _equatorial = List<Vec3>.generate(kStarCount, (i) {
  final ra = kStarPack[i * 4], dec = kStarPack[i * 4 + 1];
  final c = math.cos(dec);
  return Vec3(c * math.cos(ra), math.sin(dec), c * math.sin(ra));
}, growable: false);
final _intensities = List<double>.generate(
  kStarCount,
  (i) => starIntensity(kStarPack[i * 4 + 2]),
  growable: false,
);

/// Exposure-adapted V magnitude. The flux follows Pogson's law before a
/// logarithmic eye response; no common brightness floor for faint stars.
double starIntensity(double magnitude) {
  final flux = math.pow(10, -0.4 * magnitude).toDouble();
  return (math.log(1 + 40 * flux) / math.log(1 + 40 * math.pow(10, 0.576)))
      .clamp(0.0, 1.0);
}

double starExtinction(double altitudeRad, double turbidity) {
  if (altitudeRad <= 0) return 0;
  final degrees = altitudeRad * radToDeg;
  final airMass =
      1 /
      (math.sin(altitudeRad) + 0.50572 * math.pow(degrees + 6.07995, -1.6364));
  final coefficient = 0.12 + 0.025 * turbidity;
  return math.pow(10, -0.4 * coefficient * (airMass - 1)).toDouble();
}

double _binAlpha(int bin) => 0.004 * math.pow(250, bin / (_bins - 1));

/// Where a star lands in the picture being painted, and how much wider than
/// tall its disc is there (1 for a conformal projection). Null skips it.
typedef StarProjector = (Offset, double)? Function(Vec3 dir);

/// Catalog stars through a stereographic [camera] (Classic, SkyView).
void paintCatalogStars(
  Canvas canvas, {
  required ResolvedScene scene,
  required SkyCamera camera,
  required double time,
  double driftRad = 0,
}) {
  final forward = camera.forward, right = camera.right;
  final horizonY = camera.principal.dy;
  paintProjectedStars(
    canvas,
    scene: scene,
    time: time,
    driftRad: driftRad,
    project: (dir) {
      final denom = 1 + dir.dot(forward);
      if (denom < 0.08) return null;
      final k = 2 * camera.focal / denom;
      final p = Offset(
        camera.principal.dx + dir.dot(right) * k,
        camera.principal.dy - dir.y * k,
      );
      if (!camera.contains(p) || p.dy > horizonY + 0.5) return null;
      return (p, 1.0);
    },
  );
}

/// Visits every catalog star that shows in [scene] (above the horizon, off
/// the moon's disc, alpha at least 0.004), with its horizontal direction and
/// the same brightness as Classic (magnitude, air mass, moon glare, twinkle
/// at [time]). [alpha] is 0..1. [driftRad] turns the sky (stars and the
/// moon's mask) past the scene's sidereal time; see [siderealDriftRad].
void forEachVisibleStar(
  ResolvedScene scene,
  double time,
  void Function(int index, Vec3 dir, double alpha, double mag, double bv)
  visit, {
  double driftRad = 0,
}) {
  final vis = catalogStarVisibility(scene.sunDir.altitude * radToDeg);
  if (vis < 0.002) return;

  final pack = kStarPack;
  final lat = scene.latitudeRad;
  final sidereal = scene.siderealRad + driftRad;
  final sinLat = math.sin(lat), cosLat = math.cos(lat);
  final sinSidereal = math.sin(sidereal), cosSidereal = math.cos(sidereal);
  final moonDir = driftedDirection(scene.moonDir, lat, driftRad);
  final moonUp = smoothstep(-0.05, 0.12, moonDir.y);
  final moonGlare = 0.75 * scene.moonIllumination * moonUp;
  final twinkleAmp = (1.2 - scene.stillness).clamp(0.15, 1.2);

  for (var i = 0; i < kStarCount; i++) {
    final o = i * 4;
    final eq = _equatorial[i];
    final q = cosSidereal * eq.x + sinSidereal * eq.z;
    final dir = Vec3(
      cosSidereal * eq.z - sinSidereal * eq.x,
      sinLat * eq.y + cosLat * q,
      sinLat * q - cosLat * eq.y,
    );
    if (dir.y < 0) continue;
    if (dir.dot(moonDir) > math.cos(SkyShader.moonAngularRadius)) continue;

    final up = starExtinction(dir.altitude, scene.turbidity);
    var glare = 1.0;
    if (moonGlare > 0) {
      final m = dir.dot(moonDir).clamp(0.0, 1.0);
      glare = 1.0 - moonGlare * math.pow(m, 24).toDouble();
    }
    final twk =
        0.88 +
        0.12 * math.sin(time * (1.8 + (i % 7) * 0.35) * twinkleAmp + i * 0.17);
    final alpha = (vis * up * glare * twk * _intensities[i]).clamp(0.0, 1.0);
    if (alpha < 0.004) continue;
    visit(i, dir, alpha, pack[o + 2], pack[o + 3]);
  }
}

/// Disc size of a bright star (magnitude 1.9 or brighter) in Classic's
/// pixels; fainter stars are 1.05 px points.
double brightStarSize(double mag) =>
    (0.7 + 1.6 * math.pow(10, -0.15 * (mag + 1.44))).clamp(0.7, 2.6).toDouble();

/// Catalog stars through any [project]ion, with the same brightness
/// (magnitude, air mass, moon glare, twinkle) and colour as Classic.
/// [gain] multiplies every star's alpha and [discScale] its disc size (1 is
/// Classic). [driftRad] is as in [forEachVisibleStar].
void paintProjectedStars(
  Canvas canvas, {
  required ResolvedScene scene,
  required double time,
  required StarProjector project,
  double gain = 1,
  double discScale = 1,
  double driftRad = 0,
}) {
  for (final points in _points) {
    points.clear();
  }
  forEachVisibleStar(scene, time, (i, dir, a, mag, bv) {
    final alpha = (a * gain).clamp(0.0, 1.0);
    final at = project(dir);
    if (at == null) return;
    final (p, stretch) = at;
    if (mag <= 1.9) {
      final r = brightStarSize(mag) * 0.55 * discScale;
      final paint = Paint()..color = _tint(bv).withValues(alpha: alpha);
      if (stretch == 1.0) {
        canvas.drawCircle(p, r, paint);
      } else {
        canvas.drawOval(
          Rect.fromCenter(center: p, width: 2 * r * stretch, height: 2 * r),
          paint,
        );
      }
      return;
    }
    final bin = (math.log(alpha / 0.004) / math.log(250) * (_bins - 1))
        .round()
        .clamp(0, _bins - 1);
    _points[bin + (bv < 0.55 ? 0 : _bins)].add(p);
  }, driftRad: driftRad);

  for (var i = 0; i < _points.length; i++) {
    if (_points[i].isEmpty) continue;
    final tint = i < _bins ? const Color(0xFFC5D4FF) : const Color(0xFFFFD4B4);
    canvas.drawPoints(
      PointMode.points,
      _points[i],
      Paint()
        ..color = tint.withValues(alpha: _binAlpha(i % _bins))
        ..strokeWidth = 1.05 * discScale
        ..strokeCap = StrokeCap.round,
    );
  }
}

/// Position 0..1 between the blue-white and orange star tints for a B-V
/// colour index ([starTint] is the colour itself).
double starTintMix(double bv) => ((bv + 0.3) / 1.8).clamp(0.0, 1.0);

/// Classic's colour for a star of B-V [bv].
Color starTint(double bv) => _tint(bv);

Color _tint(double bv) {
  final t = starTintMix(bv);
  return Color.lerp(const Color(0xFFC5D4FF), const Color(0xFFFFC8A0), t)!;
}
