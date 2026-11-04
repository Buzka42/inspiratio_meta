import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_state.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

// The phone check scene: Warsaw, 2026-10-24 23:00 CEST, a 0.98 moon at 46 degrees.
final _scene = CelestialScene.resolve(
    SkyState.at(DateTime.utc(2026, 10, 24, 21), latitudeDeg: 52.2, longitudeDeg: 21.0));

void main() {
  test('per-pixel stars are unit water-frame directions above the horizon', () {
    final az = viewAzimuth(_scene);
    final d = buildSkyDetail(_scene, az, devicePixelRatio: 3);
    expect(d.starCount, greaterThan(1000));
    const st = SkyDetail.starStride;
    for (var i = 0; i < d.starCount; i++) {
      final s = d.stars.sublist(i * st, i * st + st);
      expect(math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]), closeTo(1, 1e-5));
      expect(s[1], greaterThanOrEqualTo(0));
      expect(s[3], inInclusiveRange(0, 1));
      expect(s[4], inInclusiveRange(0.44 * 3 - 1e-4, 15.9)); // physical px, packable
      expect(s[5], inInclusiveRange(0, 1));
    }
    // Night grain comes back per pixel; none by day.
    expect(d.grain, greaterThan(0));
  });

  test('star sizes scale with the device pixel ratio', () {
    final az = viewAzimuth(_scene);
    final a = buildSkyDetail(_scene, az, devicePixelRatio: 2);
    final b = buildSkyDetail(_scene, az, devicePixelRatio: 4);
    expect(b.stars[4], closeTo(2 * a.stars[4], 1e-5));
  });
}
