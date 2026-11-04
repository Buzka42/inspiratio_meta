/// The day sun as the water draws it per screen pixel (option B): its
/// water-frame direction, colour, strength and the day fade that gates the
/// sun, plus the moon and sky glow that light the clouds after dusk. Pure
/// Dart; the sun values match the GPU package's SkySun fields one to one.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:illunis_gpu/illunis_gpu.dart' show CloudNight, SkyClouds, SkySun;

import '../sky/celestial_math.dart';
import '../sky/celestial_scene.dart';
import '../sky/sky_shader.dart';
import 'reflection_geometry.dart';

/// Values for SkySun (package:illunis_gpu), in its field order.
class DaySun {
  const DaySun({
    required this.dir,
    required this.colour,
    required this.intensity,
    required this.dayFade,
    this.angularRadius = SkyShader.sunAngularRadius,
    this.night,
  });

  /// Night light for the cloud layer (null: clouds by day only).
  final CloudNight? night;

  /// Unit direction to the sun in the water frame (x right, y up, z forward).
  final (double, double, double) dir;
  final double angularRadius;

  /// Linear RGB chromaticity, brightest channel 1.
  final (double, double, double) colour;

  /// 0..1 strength of the disc and its glare.
  final double intensity;

  /// 0 night .. 1 day; 0 lets the shader skip the sun and clouds.
  final double dayFade;

  SkySun toSkySun() => SkySun(
      dir: dir, angularRadius: angularRadius, colour: colour, intensity: intensity, dayFade: dayFade);
}

/// Cloud quality tier: 0 (floor phones, the default) or 1 (flagship).
/// Debug builds only: `--dart-define=ILLUNIS_SKY_TIER=1`; other values and
/// release builds give 0.
int skyTierFrom({required bool isDebug, String spec = ''}) =>
    isDebug && spec.trim() == '1' ? 1 : 0;

/// The tier for this build, read once.
final int debugSkyTier =
    skyTierFrom(isDebug: kDebugMode, spec: const String.fromEnvironment('ILLUNIS_SKY_TIER'));

/// The cloud layer for a wind (water-frame velocity, 1 world unit = 1 m at
/// the default camera), tier and night light; other fields keep SkyClouds'
/// defaults. The same wind drives the drift by day and by night.
SkyClouds skyClouds((double, double) windVelocity, {int tier = 0, CloudNight? night}) =>
    SkyClouds(windVelocity: windVelocity, tier: tier, night: night);

/// The clouds' night light for a sun at [sunAltDeg] and the moon at
/// [moonDir] (horizontal frame) with [moonIllumination] (0..1 lit), seen by
/// a water camera facing [azimuth]. The weight is 1 - [dayFade], so the
/// layer hands over from sunlight to the night sky without a gap. The
/// moonlight ramps in as sky.frag's moonUp (moon altitude -0.05..0.12 rad
/// in y), so a set moon lights nothing. Null in full day.
CloudNight? cloudNight(double sunAltDeg, Vec3 moonDir, double moonIllumination, double azimuth) {
  final fade = 1 - dayFade(sunAltDeg);
  if (!(fade > 0)) return null;
  final m = moonDir.normalized;
  final up = smoothstep(-0.05, 0.12, m.y);
  return CloudNight(
    moonDir: worldToWater(m, azimuth),
    moonLight: (moonIllumination.clamp(0.0, 1.0) * up).toDouble(),
    fade: fade,
  );
}

/// smoothstep(-12, -2, sun altitude in degrees): the sun and its light on
/// the clouds fade out over nautical twilight, as the stars fade in (the
/// clouds' night light, [cloudNight], takes over).
double dayFade(double sunAltDeg) => smoothstep(-12, -2, sunAltDeg);

/// Relative air mass along a ray at [altDeg] (Kasten and Young 1989). Below
/// the horizon it holds the horizon value (37.9), the disc's refraction margin.
double airMass(double altDeg) {
  final h = math.max(altDeg, 0.0);
  return 1 / (math.sin(h * degToRad) + 0.50572 * math.pow(h + 6.07995, -1.6364));
}

/// Effective wavelengths (micrometres) for the linear sRGB primaries.
const _lambda = (0.68, 0.55, 0.44);

/// Zenith optical depth per channel: Rayleigh 0.0088 lambda^-4.05
/// (Bucholtz 1995 fit) plus aerosol beta lambda^-1.3 (Angstrom), with
/// Preetham's beta = 0.04608 T - 0.04586 for turbidity T. sky.frag's own
/// extinction is not used here: its Rayleigh scale (x3.1) is tuned for the
/// sky's colour and leaves a 30-degree sun orange.
(double, double, double) zenithOpticalDepth(double turbidity, {double mieScale = 1}) {
  final beta = math.max(0.04608 * turbidity - 0.04586, 0.0) * mieScale;
  double tau(double l) => 0.0088 * math.pow(l, -4.05) + beta * math.pow(l, -1.3);
  return (tau(_lambda.$1), tau(_lambda.$2), tau(_lambda.$3));
}

/// Linear transmittance of sunlight at [altDeg] relative to an overhead sun
/// (the eye adapts to the high sun, so it reads white): exp(-tau (m - 1)).
(double, double, double) sunTransmittance(double altDeg, double turbidity, {double mieScale = 1}) {
  final (r, g, b) = zenithOpticalDepth(turbidity, mieScale: mieScale);
  final m = airMass(altDeg) - 1;
  return (math.exp(-r * m), math.exp(-g * m), math.exp(-b * m));
}

/// [sunTransmittance] scaled so the brightest channel is 1: red-orange at
/// the horizon, near white from about 30 degrees.
(double, double, double) sunColour(double altDeg, double turbidity, {double mieScale = 1}) {
  final (r, g, b) = sunTransmittance(altDeg, turbidity, mieScale: mieScale);
  final top = math.max(r, math.max(g, b));
  return (r / top, g / top, b / top);
}

/// 0..1 sun strength: the cube root (a lightness-like curve) of the
/// transmitted luminance, times a visibility ramp from 1 degree below the
/// horizon (refraction margin) to 0.5 above. About 0.18 at the horizon,
/// 0.6 at 5 degrees, 0.93 at 30 and 0.99 at 60 for turbidity 2.6.
double sunIntensity(double altDeg, double turbidity, {double mieScale = 1}) {
  final (r, g, b) = sunTransmittance(altDeg, turbidity, mieScale: mieScale);
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return (math.pow(y, 1 / 3) * smoothstep(-1, 0.5, altDeg)).clamp(0.0, 1.0);
}

/// The sun for [sunDir] (horizontal frame) seen by a water camera facing
/// [azimuth], with the scene's haze. With [moonDir], the clouds' night
/// light ([cloudNight]) rides along.
DaySun daySun(Vec3 sunDir, double azimuth,
    {required double turbidity, double mieScale = 1, Vec3? moonDir, double moonIllumination = 0}) {
  final alt = sunDir.altitude * radToDeg;
  return DaySun(
    dir: worldToWater(sunDir.normalized, azimuth),
    colour: sunColour(alt, turbidity, mieScale: mieScale),
    intensity: sunIntensity(alt, turbidity, mieScale: mieScale),
    dayFade: dayFade(alt),
    night: moonDir == null ? null : cloudNight(alt, moonDir, moonIllumination, azimuth),
  );
}

/// [daySun] for [scene] at another moment of its day ([timeOfDay], a civil
/// day fraction; the per-second update) without re-resolving the scene,
/// with the moon at that moment lighting the night clouds.
DaySun daySunAt(ResolvedScene scene, double timeOfDay, double azimuth) => daySun(
    scene.sunDirectionAt(timeOfDay), azimuth,
    turbidity: scene.turbidity,
    mieScale: scene.mieScale,
    moonDir: scene.moonDirectionAt(timeOfDay),
    moonIllumination: scene.moonIllumination);
