import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/day_sky.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_shader.dart';
import 'package:illunis_client/sky/sky_state.dart';

const _t = 2.6; // the scene's turbidity at the default recovery (0.75)

void main() {
  test('ILLUNIS_SKY_TIER: 1 in debug builds only, 0 otherwise', () {
    expect(skyTierFrom(isDebug: true, spec: '1'), 1);
    expect(skyTierFrom(isDebug: true, spec: ' 1 '), 1);
    expect(skyTierFrom(isDebug: false, spec: '1'), 0);
    for (final s in ['', '0', '2', 'high', '-1']) {
      expect(skyTierFrom(isDebug: true, spec: s), 0, reason: s);
    }
  });

  test('DaySun maps onto SkySun field for field; clouds keep their defaults', () {
    final d = daySun(directionFromAltAz(20 * degToRad, 3), 3, turbidity: _t);
    final s = d.toSkySun();
    expect(s.dir, d.dir);
    expect(s.angularRadius, 0.00465);
    expect(s.colour, d.colour);
    expect(s.intensity, d.intensity);
    expect(s.dayFade, d.dayFade);
    final c = skyClouds((4, -1), tier: 1);
    expect(c.windVelocity, (4, -1));
    expect(c.tier, 1);
    expect(c.coverage, 0.45);
    expect(c.height, 1500);
  });

  test('day fade: zero by nautical night, full from 2 degrees below the horizon', () {
    expect(dayFade(-15), 0);
    expect(dayFade(-12), 0);
    expect(dayFade(-5), closeTo(0.784, 1e-3)); // smoothstep(-12, -2, -5)
    expect(dayFade(-2), 1);
    for (final a in [0.0, 5.0, 30.0, 60.0]) {
      expect(dayFade(a), 1);
    }
  });

  test('sun colour: red-orange at the horizon, near white from 30 degrees', () {
    final c0 = sunColour(0, _t), c5 = sunColour(5, _t), c30 = sunColour(30, _t);
    final c60 = sunColour(60, _t);
    expect(c0.$1, 1);
    expect(c0.$2, lessThan(0.15)); // deep orange-red
    expect(c0.$3, lessThan(0.01));
    expect(c5.$1, 1);
    expect(c5.$2, inInclusiveRange(0.35, 0.65)); // orange
    expect(c5.$3, lessThan(0.25));
    expect(c30.$2, greaterThan(0.85));
    expect(c30.$3, greaterThan(0.65));
    expect(c60.$2, greaterThan(0.95));
    expect(c60.$3, greaterThan(0.9));
    // Below the horizon it holds the horizon colour (refraction margin).
    expect(sunColour(-5, _t), sunColour(0, _t));
    // More haze reddens a low sun.
    expect(sunColour(5, 6).$2, lessThan(c5.$2));
  });

  test('sun intensity rises with altitude and is off a degree below the horizon', () {
    expect(sunIntensity(-15, _t), 0);
    expect(sunIntensity(-5, _t), 0);
    final i0 = sunIntensity(0, _t), i5 = sunIntensity(5, _t);
    final i30 = sunIntensity(30, _t), i60 = sunIntensity(60, _t);
    expect(i0, inInclusiveRange(0.05, 0.3));
    expect(i5, inInclusiveRange(0.45, 0.75));
    expect(i30, inInclusiveRange(0.85, 1.0));
    expect(i60, inInclusiveRange(0.95, 1.0));
    expect(i0 < i5 && i5 < i30 && i30 < i60, isTrue);
    expect(sunIntensity(90, _t), closeTo(1, 1e-9));
  });

  test('air mass is 1 overhead and about 38 at the horizon', () {
    expect(airMass(90), closeTo(1, 1e-3));
    expect(airMass(30), closeTo(2, 0.01));
    expect(airMass(0), closeTo(37.9, 0.2));
    expect(airMass(-3), airMass(0));
  });

  test('daySun gives the water-frame direction and SkySun fields', () {
    // Sun 30 degrees up due south; camera facing south: straight ahead, up.
    final dir = directionFromAltAz(30 * degToRad, math.pi);
    final s = daySun(dir, math.pi, turbidity: _t);
    expect(s.dir.$1, closeTo(0, 1e-9));
    expect(s.dir.$2, closeTo(0.5, 1e-9));
    expect(s.dir.$3, closeTo(math.cos(30 * degToRad), 1e-9));
    expect(s.angularRadius, SkyShader.sunAngularRadius);
    expect(s.angularRadius, 0.00465);
    expect(s.dayFade, 1);
    expect(s.intensity, sunIntensity(30, _t));
    // Camera facing east: the southern sun is on the right.
    expect(daySun(dir, math.pi / 2, turbidity: _t).dir.$1, closeTo(math.cos(30 * degToRad), 1e-9));
  });

  test('daySunAt follows the scene sun and moves about 0.25 degrees a minute', () {
    final scene = CelestialScene.resolve(SkyState.at(DateTime.utc(2026, 10, 24, 11),
        latitudeDeg: 52.2, longitudeDeg: 21.0));
    final az = viewAzimuth(scene);
    final now = daySunAt(scene, scene.state.timeOfDay, az);
    final (x, y, z) = worldToWater(scene.sunDir, az);
    expect(now.dir.$1, closeTo(x, 1e-9));
    expect(now.dir.$2, closeTo(y, 1e-9));
    expect(now.dir.$3, closeTo(z, 1e-9));
    final later = daySunAt(scene, scene.state.timeOfDay + 1 / 1440, az);
    final cosA = now.dir.$1 * later.dir.$1 + now.dir.$2 * later.dir.$2 + now.dir.$3 * later.dir.$3;
    expect(math.acos(cosA.clamp(-1.0, 1.0)) * radToDeg, inInclusiveRange(0.1, 0.3));
  });

  test('cloudNight: weight 1 - dayFade, moonlight from illumination and a risen moon', () {
    final moonUp = directionFromAltAz(30 * degToRad, math.pi);
    expect(cloudNight(10, moonUp, 1, 0), isNull); // full day
    final n = cloudNight(-20, moonUp, 0.8, 0.4)!;
    expect(n.fade, 1);
    expect(n.moonLight, closeTo(0.8, 1e-9));
    final (x, y, z) = worldToWater(moonUp, 0.4);
    expect(n.moonDir.$1, closeTo(x, 1e-9));
    expect(n.moonDir.$2, closeTo(y, 1e-9));
    expect(n.moonDir.$3, closeTo(z, 1e-9));
    // Twilight hands over: the night weight and the day fade sum to 1.
    final tw = cloudNight(-7, moonUp, 1, 0)!;
    expect(tw.fade + dayFade(-7), closeTo(1, 1e-9));
    // A set moon lights nothing; the sky glow still shows the clouds.
    final set = cloudNight(-20, directionFromAltAz(-10 * degToRad, 0), 1, 0)!;
    expect(set.moonLight, 0);
    expect(set.fade, 1);
  });

  test('daySunAt carries the scene moon into the clouds at night, and skyClouds keeps it', () {
    final scene = CelestialScene.resolve(SkyState.at(DateTime.utc(2026, 10, 24, 22),
        latitudeDeg: 52.2, longitudeDeg: 21.0));
    final az = viewAzimuth(scene);
    final d = daySunAt(scene, scene.state.timeOfDay, az);
    expect(d.dayFade, 0);
    final n = d.night!;
    expect(n.fade, 1);
    final (x, _, z) = worldToWater(scene.moonDir, az);
    expect(n.moonDir.$1, closeTo(x, 1e-6));
    expect(n.moonDir.$3, closeTo(z, 1e-6));
    expect(n.moonLight, lessThanOrEqualTo(scene.moonIllumination + 1e-9));
    final c = skyClouds((4, 0), night: n);
    expect(c.night, n);
    expect(c.windVelocity, (4, 0));
  });
}
