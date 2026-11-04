import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/day_sky.dart';
import 'package:illunis_client/app/illunis_root.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/app/sky_debug_override.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/water_port.dart';
import 'package:illunis_client/sky/wind.dart';
import 'package:illunis_client/core/fog_settings.dart';

AppController _controller() => AppController(
    fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: SilentTts());

Widget _root(ValueNotifier<DaySun?> sun, {DateTime? now, SkyOverride o = SkyOverride.none}) =>
    IllunisRoot(
      controller: _controller(),
      waterProgramLoader: () => Future.error(StateError('no shader in tests')),
      now: now,
      skyOverride: o,
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      sun: sun,
    );

void main() {
  wiringTests();
  testWidgets('the sun is recomputed every second on the wall clock', (t) async {
    final sun = ValueNotifier<DaySun?>(null);
    var updates = 0;
    sun.addListener(() => updates++);
    await t.pumpWidget(_root(sun));
    expect(sun.value, isNotNull);
    final first = updates;
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(updates - first, greaterThanOrEqualTo(3));
    await t.pumpWidget(const SizedBox());
  });

  for (final (name, now, o) in [
    ('a fixed clock', DateTime.utc(2026, 10, 24, 11), SkyOverride.none),
    ('ILLUNIS_SKY_TIME', null, SkyOverride(time: DateTime.utc(2026, 10, 24, 11))),
  ]) {
    testWidgets('$name keeps the sun still', (t) async {
      final sun = ValueNotifier<DaySun?>(null);
      await t.pumpWidget(_root(sun, now: now, o: o));
      final d0 = sun.value!.dir;
      expect(d0.$2, greaterThan(0.3)); // 11:00 UTC at Greenwich: the sun is well up
      await t.pump(const Duration(seconds: 5));
      expect(sun.value!.dir, d0);
      expect(sun.value!.dayFade, 1);
      await t.pumpWidget(const SizedBox());
    });
  }
}

/// A per-pixel port that records what the root hands it.
class _RecordingPort implements WaterPort {
  WaterInputs? last;
  @override
  bool get drawsSkyDetail => true;
  @override
  ValueListenable<ReflectionOptics> get optics => _optics;
  final _optics = ValueNotifier(ReflectionOptics.gpu);
  @override
  Widget build(WaterInputs inputs) {
    last = inputs;
    return const SizedBox.expand();
  }
}

void wiringTests() {
  testWidgets('a per-pixel port gets the sun and wind-driven clouds once the base is baked',
      (t) async {
    final port = _RecordingPort();
    final wind = WindSource(Wind.westerly);
    await t.pumpWidget(IllunisRoot(
      controller: _controller(),
      water: port,
      now: DateTime.utc(2026, 10, 24, 11),
      skyOverride: SkyOverride.none,
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      wind: wind,
      skyTier: 1,
    ));
    for (var i = 0; i < 20 && port.last?.sun == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
    }
    final i = port.last!;
    expect(i.sun, isNotNull);
    expect(i.sun!.dayFade, 1);
    expect(i.sun!.angularRadius, 0.00465);
    expect(i.clouds!.tier, 1);
    final speed = math.sqrt(math.pow(i.clouds!.windVelocity.$1, 2) + math.pow(i.clouds!.windVelocity.$2, 2));
    expect(speed, closeTo(4, 1e-9));
    // A new wind reaches the water without a re-bake.
    wind.value = const Wind(fromRad: 0, speedMps: 9);
    await t.pump();
    final v = port.last!.clouds!.windVelocity;
    expect(math.sqrt(v.$1 * v.$1 + v.$2 * v.$2), closeTo(9, 1e-9));
    await t.pumpWidget(const SizedBox());
    wind.dispose();
  });

  testWidgets('at night the clouds stay on, moonlit, with the same wind', (t) async {
    final port = _RecordingPort();
    final wind = WindSource(Wind.westerly);
    await t.pumpWidget(IllunisRoot(
      controller: _controller(),
      water: port,
      now: DateTime.utc(2026, 10, 24, 22),
      skyOverride: SkyOverride.none,
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      wind: wind,
    ));
    for (var i = 0; i < 20 && port.last?.clouds == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
    }
    final i = port.last!;
    expect(i.sun!.dayFade, 0);
    expect(i.clouds!.night, isNotNull);
    expect(i.clouds!.night!.fade, 1);
    final v = i.clouds!.windVelocity;
    expect(math.sqrt(v.$1 * v.$1 + v.$2 * v.$2), closeTo(4, 1e-9));
    await t.pumpWidget(const SizedBox());
    wind.dispose();
  });
}
