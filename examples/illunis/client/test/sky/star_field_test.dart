import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_state.dart';
import 'package:illunis_client/sky/star_catalog.dart';
import 'package:illunis_client/sky/star_field.dart';

double _expected(double mag) {
  final flux = math.pow(10, -0.4 * mag);
  return math.log(1 + 40 * flux) / math.log(1 + 40 * math.pow(10, 0.576));
}

void main() {
  test('catalog has 5,070 rows of four floats, brightest first', () {
    expect(kStarCount, 5070);
    expect(kStarPack.length, kStarCount * 4);
    expect(catalogStarAt(0).vMag, closeTo(-1.44, 1e-6)); // Sirius
    expect(catalogStarAt(kStarCount - 1).vMag, lessThanOrEqualTo(6.0));
    expect(catalogStarByName('Polaris'), isNotNull);
  });

  test('brightness at magnitude 0 and 6', () {
    // Hand values: 0 -> ln(41)/ln(151.68) = 0.7395; 6 -> 0.0294.
    expect(starIntensity(0), closeTo(0.7395, 1e-3));
    expect(starIntensity(6), closeTo(0.0294, 1e-3));
    expect(starIntensity(0), closeTo(_expected(0), 1e-12));
    expect(starIntensity(6), closeTo(_expected(6), 1e-12));
  });

  test(
    'brightness is 1 at Sirius, clamps above it, and falls with magnitude',
    () {
      expect(starIntensity(-1.44), closeTo(1.0, 1e-3));
      expect(starIntensity(-4), 1.0);
      for (var m = -1.0; m < 6; m += 0.5) {
        expect(starIntensity(m), greaterThan(starIntensity(m + 0.5)));
      }
    },
  );

  test('extinction is 0 below the horizon and near 1 at the zenith', () {
    expect(starExtinction(-0.1, 2), 0);
    expect(starExtinction(math.pi / 2, 2), closeTo(1, 1e-3));
    expect(starExtinction(0.05, 6), lessThan(starExtinction(0.05, 2)));
  });

  test('stars appear only after civil dusk', () {
    expect(catalogStarVisibility(0), 0);
    expect(catalogStarVisibility(-20), 1);
  });

  group('sidereal drift', () {
    // A local night, 52.5 N 13.4 E (UTC+1 in late October).
    final t0 = DateTime(2026, 10, 25, 23, 0);
    ResolvedScene at(DateTime t) => CelestialScene.resolve(
      SkyState.at(t, latitudeDeg: 52.5, longitudeDeg: 13.4),
    );
    double angleDeg(Vec3 a, Vec3 b) =>
        math.acos(a.normalized.dot(b.normalized).clamp(-1.0, 1.0)) * radToDeg;
    double wrapDiff(double a, double b) {
      final d = wrapAngle(a - b);
      return d > math.pi ? d - 2 * math.pi : d;
    }

    test('one revolution per sidereal day, about 15.04 degrees an hour', () {
      const day = Duration(hours: 23, minutes: 56, milliseconds: 4091);
      expect(siderealDriftRad(day), closeTo(2 * math.pi, 1e-4));
      expect(
        siderealDriftRad(const Duration(hours: 1)) * radToDeg,
        closeTo(15.041, 1e-3),
      );
      expect(siderealDriftRad(Duration.zero), 0);
    });

    test('the drift matches the scene resolved later from the clock', () {
      final a = at(t0), b = at(t0.add(const Duration(hours: 1)));
      final drift = siderealDriftRad(const Duration(hours: 1));
      // The scene anchors sidereal time at the day's solar transit, which
      // leaves it within a few seconds of the true rate over an hour.
      expect(wrapDiff(b.siderealRad, a.siderealRad), closeTo(drift, 1e-3));
      final lat = a.latitudeRad;
      for (final name in ['Sirius', 'Vega', 'Capella', 'Betelgeuse']) {
        final star = catalogStarByName(name)!;
        final later = catalogStarDirection(star, b.siderealRad, lat);
        final drifted = driftedDirection(
          catalogStarDirection(star, a.siderealRad, lat),
          lat,
          drift,
        );
        expect(angleDeg(drifted, later), lessThan(0.05), reason: name);
      }
    });

    test('stars turn about the pole: Polaris holds, Vega moves west', () {
      final lat = 52.5 * degToRad;
      final drift = siderealDriftRad(const Duration(hours: 1));
      expect(
        angleDeg(
          driftedDirection(celestialPole(lat), lat, drift),
          celestialPole(lat),
        ),
        lessThan(1e-9),
      );
      final vega = catalogStarByName('Vega')!;
      final s = at(t0).siderealRad;
      final now = catalogStarDirection(vega, s, lat);
      final later = driftedDirection(now, lat, drift);
      // Hour angle grows: the star is carried westward (clockwise from the
      // north, seen from inside the sphere).
      expect(angleDeg(now, later), greaterThan(5));
      expect(
        angleDeg(later, catalogStarDirection(vega, s + drift, lat)),
        lessThan(1e-6),
      );
    });

    test('forEachVisibleStar with drift places stars at the later time', () {
      final a = at(t0), b = at(t0.add(const Duration(minutes: 30)));
      final drift = siderealDriftRad(const Duration(minutes: 30));
      final drifted = <int, Vec3>{}, later = <int, Vec3>{};
      forEachVisibleStar(
        a,
        0,
        (i, d, _, _, _) => drifted[i] = d,
        driftRad: drift,
      );
      forEachVisibleStar(b, 0, (i, d, _, _, _) => later[i] = d);
      expect(drifted, isNotEmpty);
      var compared = 0;
      for (final e in drifted.entries) {
        final l = later[e.key];
        if (l == null) continue;
        expect(angleDeg(e.value, l), lessThan(0.05));
        compared++;
      }
      expect(compared, greaterThan(drifted.length * 0.95));
    });

    test(
      'the moon drifts slower than the stars by about half a degree an hour',
      () {
        final a = at(t0), b = at(t0.add(const Duration(hours: 1)));
        final drift = siderealDriftRad(const Duration(hours: 1));
        final carried = driftedDirection(a.moonDir, a.latitudeRad, drift);
        final lag = angleDeg(carried, b.moonDir);
        expect(lag, greaterThan(0.2));
        expect(lag, lessThan(1.2));
        // Against the sky it still moves most of the stars' rate.
        expect(angleDeg(a.moonDir, b.moonDir), greaterThan(5));
      },
    );
  });
}
