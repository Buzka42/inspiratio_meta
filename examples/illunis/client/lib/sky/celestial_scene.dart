import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'celestial_math.dart';
import 'sky_state.dart';

double _siderealAt(SkyState state, double time) {
  final transitEpoch = state.epochDays + state.solarNoon;
  final transitRa = equatorialFromEcliptic(
    sunEclipticLongitude(transitEpoch),
    obliquity: obliquityAt(transitEpoch),
  ).ra;
  return wrapAngle(
    transitRa + (time - state.solarNoon) * 2 * math.pi * 1.00273790935,
  );
}

final _moonEventCache = <(double, double, int, int), (double?, double?)>{};

(double?, double?) _moonEvents(SkyState state, double phaseOffset) {
  final key = (
    state.epochDays,
    state.latitudeDeg,
    (state.solarNoon * 100000).round(),
    (phaseOffset * 10000).round(),
  );
  final cached = _moonEventCache[key];
  if (cached != null) return cached;
  final latitude = state.latitudeDeg * degToRad;
  double altitude(double t) =>
      topocentricMoonDirection(
        epoch: state.epochDays + t,
        sidereal: _siderealAt(state, t),
        latitude: latitude,
        phaseOffset: phaseOffset,
      ).altitude -
      riseSetAltitudeRad;
  double? rise, set;
  var previous = altitude(0);
  for (var i = 1; i <= 96; i++) {
    final current = altitude(i / 96);
    if ((previous < 0) != (current < 0)) {
      var lo = (i - 1) / 96, hi = i / 96;
      for (var j = 0; j < 18; j++) {
        final mid = (lo + hi) / 2;
        if ((altitude(mid) < 0) == (previous < 0)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      if (previous < current) {
        rise = (lo + hi) / 2;
      } else {
        set = (lo + hi) / 2;
      }
    }
    previous = current;
  }
  if (_moonEventCache.length >= 16) {
    _moonEventCache.remove(_moonEventCache.keys.first);
  }
  return _moonEventCache[key] = (rise, set);
}

/// Pure geometry and atmosphere parameters resolved from a [SkyState].
///
/// No widgets, no clock, no paint. Everything here is unit-testable and is
/// the single source of truth for both the shader (through uniforms) and the
/// Dart overlay (through [sunDirectionAt] and friends), so the drawn sun and
/// the annotated sun are always the same sun.
@immutable
class ResolvedScene {
  const ResolvedScene({
    required this.state,
    required this.sunDir,
    required this.moonDir,
    required this.siderealRad,
    required this.latitudeRad,
    required this.sunDeclinationRad,
    required this.moonDeclinationRad,
    required this.moonHourAngleOffsetRad,
    required this.moonRaRate,
    required this.moonDecRate,
    required this.moonDistance,
    required this.moonIllumination,
    required this.sunrise,
    required this.sunset,
    required this.moonrise,
    required this.moonset,
    required this.turbidity,
    required this.mieScale,
    required this.exposure,
    required this.stillness,
    required this.trackAzimuthRad,
    required this.planets,
  });

  /// The five naked-eye planets, in [Planet] order.
  final List<PlanetPosition> planets;

  final SkyState state;

  /// Unit direction to the sun, horizontal frame.
  final Vec3 sunDir;

  /// Unit direction to the moon, horizontal frame.
  final Vec3 moonDir;

  /// Local sidereal time, radians. Rotates the star field.
  final double siderealRad;

  final double latitudeRad;
  final double sunDeclinationRad;
  final double moonDeclinationRad;

  /// `H_moon = H_sun + offset`; lets the overlay trace the moon's path.
  final double moonHourAngleOffsetRad;
  final double moonRaRate, moonDecRate, moonDistance;

  /// `0..1`, fraction of the disc lit.
  final double moonIllumination;

  /// Day fractions, null when the body never crosses the horizon today.
  final double? sunrise, sunset, moonrise, moonset;

  /// Atmospheric haze, `~2` crisp to `~8` murky.
  final double turbidity;

  /// Multiplier on aerosol scattering; warmth of the low sky.
  final double mieScale;

  /// Tone-mapping exposure, already adapted for the sun's altitude.
  final double exposure;

  /// `0..1` — `1` is a perfectly still night (no grain breath, slow twinkle).
  final double stillness;

  /// Where the camera looks by default: the sun by day; a risen, lit moon
  /// at night; otherwise south, so the catalog sky is in the window.
  final double trackAzimuthRad;

  double get sunAltitudeRad => sunDir.altitude;
  double get sunAzimuthRad => sunDir.azimuth;
  double get moonAltitudeRad => moonDir.altitude;
  double get moonAzimuthRad => moonDir.azimuth;

  double? get dayLength {
    if (sunrise == null || sunset == null) return null;
    var d = sunset! - sunrise!;
    if (d < 0) d += 1;
    return d;
  }

  /// `0` full night, `1` full day; the sun's altitude on a perceptual ramp.
  double get dayness {
    final a = sunAltitudeRad * radToDeg;
    return smoothstep(-12, 4, a);
  }

  /// Shared header/instrument adaptation, paper at night and slate by day.
  double get skyInkBlend => smoothstep(0.55, 0.85, dayness);

  /// Sun direction at another time of the same day, for path drawing.
  Vec3 sunDirectionAt(double timeOfDay) {
    final epoch = state.epochDays + timeOfDay;
    final eq = equatorialFromEcliptic(
      sunEclipticLongitude(epoch),
      obliquity: obliquityAt(epoch),
    );
    return horizontalDirection(
      eq.dec,
      _siderealAt(state, timeOfDay) - eq.ra,
      latitudeRad,
    );
  }

  /// The nearest rise-to-set arc, including either side of civil midnight.
  /// Polar moons without a crossing are bounded to one day on each side.
  ({double start, double end}) get moonPathRange {
    const step = 1 / 96;
    final now = state.timeOfDay;
    var seed = now;
    if (moonDirectionAt(seed).y < 0) {
      for (var i = 1; i <= 96; i++) {
        final before = now - i * step;
        final after = now + i * step;
        if (moonDirectionAt(before).y >= 0) {
          seed = before;
          break;
        }
        if (moonDirectionAt(after).y >= 0) {
          seed = after;
          break;
        }
      }
      if (moonDirectionAt(seed).y < 0) return (start: now, end: now);
    }
    double crossing(int direction) {
      var inside = seed;
      for (var i = 1; i <= 96; i++) {
        final outside = seed + direction * i * step;
        if (moonDirectionAt(outside).y < 0) {
          var edge = outside;
          for (var j = 0; j < 18; j++) {
            final mid = (inside + edge) / 2;
            if (moonDirectionAt(mid).y >= 0) {
              inside = mid;
            } else {
              edge = mid;
            }
          }
          return inside;
        }
        inside = outside;
      }
      return inside;
    }

    return (start: crossing(-1), end: crossing(1));
  }

  Vec3 moonDirectionAt(double timeOfDay) {
    final epoch = state.epochDays + state.timeOfDay;
    final phaseOffset =
        wrapAngle(
          sunEclipticLongitude(epoch) +
              state.moonPhase * 2 * math.pi -
              moonEcliptic(epoch).longitude +
              math.pi,
        ) -
        math.pi;
    return topocentricMoonDirection(
      epoch: state.epochDays + timeOfDay,
      sidereal: _siderealAt(state, timeOfDay),
      latitude: latitudeRad,
      phaseOffset: phaseOffset,
    );
  }

  String describeMoonPhase() {
    final p = state.moonPhase;
    if (p < 0.02 || p > 0.98) return 'New moon';
    if (p < 0.23) return 'Waxing crescent';
    if (p < 0.27) return 'First quarter';
    if (p < 0.48) return 'Waxing gibbous';
    if (p < 0.52) return 'Full moon';
    if (p < 0.73) return 'Waning gibbous';
    if (p < 0.77) return 'Last quarter';
    return 'Waning crescent';
  }

  String describeTwilight() {
    final a = sunAltitudeRad * radToDeg;
    if (a >= 0) return 'Daylight';
    if (a >= -6) return 'Civil twilight';
    if (a >= -12) return 'Nautical twilight';
    if (a >= -18) return 'Astronomical twilight';
    return 'Night';
  }
}

@immutable
class PlanetPosition {
  const PlanetPosition({
    required this.planet,
    required this.dir,
    required this.magnitude,
    required this.elongationRad,
    required this.visibility,
    required this.brightness,
  });

  final Planet planet;
  final Vec3 dir;
  final double magnitude;
  final double elongationRad;

  /// `0..1`: above the horizon and the sky dark enough to show it.
  final double visibility;

  /// `0..1` point intensity for the shader.
  final double brightness;
}

class CelestialScene {
  const CelestialScene._();

  static ResolvedScene resolve(SkyState s) {
    final lat = s.latitudeDeg * degToRad;
    final epoch = s.epochDays + s.timeOfDay;
    // The Sun from the same element set as the planets, so they agree.
    final lambdaSun = sunEclipticLongitude(epoch);
    final eqSun = equatorialFromEcliptic(
      lambdaSun,
      obliquity: obliquityAt(epoch),
    );
    final dec = eqSun.dec;
    final sidereal = _siderealAt(s, s.timeOfDay);
    final hSun = sidereal - eqSun.ra;
    final sunDir = horizontalDirection(dec, hSun, lat);

    // Phase overrides rotate the real orbit; live phase has zero offset.
    final moonOrbit = moonEcliptic(epoch);
    final lambdaMoon = lambdaSun + s.moonPhase * 2 * math.pi;
    final phaseOffset =
        wrapAngle(lambdaMoon - moonOrbit.longitude + math.pi) - math.pi;
    final eqMoon = equatorialFromEcliptic(
      lambdaMoon,
      latitude: moonOrbit.latitude,
      obliquity: obliquityAt(epoch),
    );
    final moonOffset =
        sidereal - solarHourAngle(s.timeOfDay, s.solarNoon) - eqMoon.ra;
    final moonDir = lunarParallax(
      horizontalDirection(eqMoon.dec, sidereal - eqMoon.ra, lat),
      moonOrbit.distance,
      lat,
    );
    final illum = (1 - sunDir.dot(moonDir)) / 2;
    final laterOrbit = moonEcliptic(epoch + 0.5);
    final earlierOrbit = moonEcliptic(epoch - 0.5);
    final later = equatorialFromEcliptic(
      laterOrbit.longitude + phaseOffset,
      latitude: laterOrbit.latitude,
      obliquity: obliquityAt(epoch),
    );
    final earlier = equatorialFromEcliptic(
      earlierOrbit.longitude + phaseOffset,
      latitude: earlierOrbit.latitude,
      obliquity: obliquityAt(epoch),
    );

    final sunAltDeg = sunDir.altitude * radToDeg;
    final planets = <PlanetPosition>[
      for (final p in Planet.values)
        _planet(p, epoch, sidereal, lat, sunAltDeg),
    ];

    final h0 = hourAngleAtAltitude(dec, lat, riseSetAltitudeRad);
    final sunrise = h0 == null ? null : _frac(s.solarNoon - h0 / (2 * math.pi));
    final sunset = h0 == null ? null : _frac(s.solarNoon + h0 / (2 * math.pi));
    final moonEvents = _moonEvents(s, phaseOffset);

    // Vitals reach the atmosphere lightly. Recovery is how far you can see;
    // strain warms the low sky; sleep decides how still the night is.
    final recovery = s.recovery ?? 0.75;
    final strain = s.strain ?? 0.2;
    final sleep = s.sleepScore ?? 0.75;
    final turbidity = 1.6 + (1 - recovery) * 4.0;
    final mieScale = 1.0 + strain * 0.9;
    final stillness = 0.35 + sleep * 0.65;

    final altDeg = sunDir.altitude * radToDeg;
    // Photographic adaptation, in the shader's already-compressed units:
    // noon sits at 0.5 (the classic Preetham/ACES pairing), night opens up.
    final exposure = _lerp(1.25, 0.26, _smoothstep(-14, 6, altDeg));

    // Day follows the sun. Night follows a risen, lit moon; otherwise
    // south — not the azimuth of a sun that has already set, which would
    // put Orion and the rest of the catalog off the screen.
    final night = _smoothstep(-6, -14, altDeg);
    final wSun = (0.06 + _smoothstep(-14, -2, altDeg)) * (1 - night);
    final wMoon =
        _smoothstep(0, 12, moonDir.altitude * radToDeg) *
        (0.15 + 0.85 * illum) *
        night;
    final moonShare = wMoon / (wMoon + 0.35);
    final wSouth = night * (1 - moonShare);
    final track = _weightedAzimuth(
      [sunDir.azimuth, moonDir.azimuth, math.pi],
      [wSun, wMoon, wSouth],
    );

    return ResolvedScene(
      state: s,
      sunDir: sunDir,
      moonDir: moonDir,
      siderealRad: sidereal,
      latitudeRad: lat,
      sunDeclinationRad: dec,
      moonDeclinationRad: eqMoon.dec,
      moonHourAngleOffsetRad: moonOffset,
      moonRaRate: wrapAngle(later.ra - earlier.ra + math.pi) - math.pi,
      moonDecRate: later.dec - earlier.dec,
      moonDistance: moonOrbit.distance,
      moonIllumination: illum,
      sunrise: sunrise,
      sunset: sunset,
      moonrise: moonEvents.$1,
      moonset: moonEvents.$2,
      turbidity: turbidity,
      mieScale: mieScale,
      exposure: exposure,
      stillness: stillness,
      trackAzimuthRad: track,
      planets: planets,
    );
  }

  static PlanetPosition _planet(
    Planet p,
    double epoch,
    double sidereal,
    double lat,
    double sunAltDeg,
  ) {
    final eq = planetEquatorial(p, epoch);
    final dir = horizontalDirection(eq.dec, sidereal - eq.ra, lat);
    final mag = planetMagnitude(p, eq.distanceAu);
    // Bright planets show from civil twilight, faint ones from nautical;
    // everything fades into the horizon's air.
    final darkEnough = mag < -1.5
        ? smoothstep(-2.0, -7.0, sunAltDeg)
        : smoothstep(-6.0, -11.0, sunAltDeg);
    final up = smoothstep(-0.5, 4.0, dir.altitude * radToDeg);
    final visibility = darkEnough * up;
    // Point brightness on a magnitude scale, Venus ≈ 1, +1 mag ≈ 0.12.
    final brightness = math
        .pow(10, -0.4 * (mag + 4.2))
        .toDouble()
        .clamp(0.0, 1.0);
    return PlanetPosition(
      planet: p,
      dir: dir,
      magnitude: mag,
      elongationRad: eq.elongationRad,
      visibility: visibility,
      brightness: brightness,
    );
  }

  static double _frac(double v) => v - v.floorToDouble();
  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _smoothstep(double e0, double e1, double x) =>
      smoothstep(e0, e1, x);

  static double _weightedAzimuth(List<double> az, List<double> w) {
    var x = 0.0, y = 0.0;
    for (var i = 0; i < az.length; i++) {
      x += math.cos(az[i]) * w[i];
      y += math.sin(az[i]) * w[i];
    }
    if (x == 0 && y == 0) return az.first;
    return wrapAngle(math.atan2(y, x));
  }
}
