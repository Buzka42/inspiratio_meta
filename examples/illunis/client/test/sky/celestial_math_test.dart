import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_state.dart';

// Reference values: NASA/JPL Horizons DE441, airless apparent alt/az,
// observer Warsaw 52.23 N 21.01 E, elevation 0 (copied from the original
// app's test/sky/fixtures/warsaw_horizons_2026.json).
const _lat = 52.23, _lon = 21.01;

double _angleError(double a, double b) => ((a - b + 180) % 360 - 180).abs();

/// Scene for a civil date in a fixed UTC offset, at local day fraction [t].
ResolvedScene _scene(int y, int m, int d, double offsetHours, double t) {
  final midnight = epochDaysForDate(y, m, d) - offsetHours / 24;
  return CelestialScene.resolve(
    SkyState(
      timeOfDay: t,
      dayOfYear: civilDayOfYear(DateTime.utc(y, m, d)),
      epochDays: midnight,
      latitudeDeg: _lat,
      moonPhase: moonPhaseAt(midnight + t),
      solarNoon: solarNoonFor(midnight + t, _lon, offsetHours),
    ),
  );
}

void _expectAltAz(Vec3 dir, double altDeg, double azDeg, String what) {
  expect((dir.altitude * radToDeg - altDeg).abs(), lessThan(0.5),
      reason: '$what altitude');
  expect(_angleError(dir.azimuth * radToDeg, azDeg), lessThan(0.5),
      reason: '$what azimuth');
}

void main() {
  group('June 2026 solstice, Warsaw (CEST, UTC+2)', () {
    // 2026-06-21 10:00 UTC = 12:00 local.
    final noon = _scene(2026, 6, 21, 2, 0.5);

    test('sun position matches Horizons within 0.5 deg', () {
      _expectAltAz(noon.sunDir, 60.314110807, 162.310824694, 'sun');
    });

    test('solar declination is near +23.44 deg', () {
      expect(noon.sunDeclinationRad * radToDeg, closeTo(23.44, 0.05));
    });

    test('sunrise and sunset match the almanac within 4 minutes', () {
      // Almanac (timeanddate.com, Warsaw): sunrise 04:14, sunset 21:01 CEST.
      expect(noon.sunrise! * 24 * 60, closeTo(4 * 60 + 14, 4));
      expect(noon.sunset! * 24 * 60, closeTo(21 * 60 + 1, 4));
    });

    test('moon at 2026-06-21 13:00 UTC matches Horizons', () {
      final s = _scene(2026, 6, 21, 2, 15 / 24);
      _expectAltAz(s.moonDir, 22.373153797, 124.102179795, 'moon');
      expect(s.moonIllumination * 100, closeTo(46.88592, 2));
    });
  });

  group('December 2026 solstice, Warsaw (CET, UTC+1)', () {
    test('sun at 2026-12-21 11:00 UTC matches Horizons', () {
      final s = _scene(2026, 12, 21, 1, 0.5);
      _expectAltAz(s.sunDir, 14.117383156, 186.147125211, 'sun');
      expect(s.sunDeclinationRad * radToDeg, closeTo(-23.44, 0.05));
    });

    test('moon at 2026-12-21 20:00 UTC matches Horizons', () {
      final s = _scene(2026, 12, 21, 1, 21 / 24);
      _expectAltAz(s.moonDir, 61.930515782, 172.940043767, 'moon');
      expect(s.moonIllumination * 100, closeTo(92.50286, 2));
    });

    test('moonrise and moonset are found for the day', () {
      final s = _scene(2026, 12, 21, 1, 0.5);
      expect(s.moonrise, isNotNull);
      expect(s.moonset, isNotNull);
      expect(s.moonrise!, inInclusiveRange(0, 1));
    });
  });

  test('moon phase is new at the 2024-04-08 total solar eclipse', () {
    // New moon 2024-04-08 18:21 UTC.
    final p = moonPhaseFor(DateTime.utc(2024, 4, 8, 18, 21));
    expect(_angleError(p * 360, 0), lessThan(2));
    expect(moonIlluminatedFraction(p), lessThan(0.01));
  });

  test('moon phase is full on 2024-04-23 23:49 UTC', () {
    final p = moonPhaseFor(DateTime.utc(2024, 4, 23, 23, 49));
    expect(p, closeTo(0.5, 0.01));
  });

  test('epochDaysForDate is zero half a day before J2000.0', () {
    expect(epochDaysForDate(2000, 1, 1), -0.5);
  });
}
