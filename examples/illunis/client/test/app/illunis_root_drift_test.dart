import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/illunis_root.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/app/sky_debug_override.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/water_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_state.dart';
import 'package:illunis_client/sky/star_field.dart';

AppController _controller() => AppController(
    fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: SilentTts());

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

final _t0 = DateTime.utc(2026, 10, 24, 22);

void main() {
  testWidgets('the drift angle advances with the injected clock', (t) async {
    var now = _t0;
    final drift = ValueNotifier<double>(-1);
    await t.pumpWidget(IllunisRoot(
      controller: _controller(),
      waterProgramLoader: () => Future.error(StateError('no shader in tests')),
      skyOverride: SkyOverride.none,
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      clock: () => now,
      drift: drift,
    ));
    expect(drift.value, 0);
    now = _t0.add(const Duration(seconds: 40));
    await t.pump(const Duration(seconds: 1));
    expect(drift.value, closeTo(siderealDriftRad(const Duration(seconds: 40)), 1e-12));
    now = _t0.add(const Duration(seconds: 50));
    await t.pump(const Duration(seconds: 1));
    // 50 s of sidereal turn: about 0.209 degrees.
    expect(drift.value * 180 / 3.141592653589793, closeTo(0.209, 0.001));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a fixed time keeps the drift at zero', (t) async {
    final drift = ValueNotifier<double>(-1);
    await t.pumpWidget(IllunisRoot(
      controller: _controller(),
      waterProgramLoader: () => Future.error(StateError('no shader in tests')),
      now: _t0,
      skyOverride: SkyOverride.none,
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      clock: () => _t0.add(const Duration(hours: 1)),
      drift: drift,
    ));
    await t.pump(const Duration(seconds: 3));
    expect(drift.value, 0);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Reflection rebuilds the drifted stars without a new bake', (t) async {
    var now = _t0;
    final port = _RecordingPort();
    await t.pumpWidget(IllunisRoot(
      controller: _controller(),
      water: port,
      skyOverride: SkyOverride.none,
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      clock: () => now,
    ));
    for (var i = 0; i < 20 && port.last?.detail == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
    }
    final first = port.last!.detail!;
    final sky = port.last!.sky;
    expect(first.stars.length, greaterThan(60));

    now = _t0.add(const Duration(seconds: 30));
    await t.pump(const Duration(seconds: 1));
    final moved = port.last!.detail!;
    expect(identical(moved, first), isFalse);
    expect(port.last!.sky, same(sky)); // no re-bake

    final scene = CelestialScene.resolve(SkyState.at(_t0,
        latitudeDeg: greenwichDefaultLat, longitudeDeg: greenwichDefaultLng));
    final d = siderealDriftRad(const Duration(seconds: 30));
    final want = buildSkyDetail(scene, viewAzimuth(scene, driftRad: d), driftRad: d);
    expect(moved.stars.length, want.stars.length);
    for (var i = 0; i < 3; i++) {
      expect(moved.stars[i], closeTo(want.stars[i], 1e-5));
    }
    expect(moved.stars[0], isNot(closeTo(first.stars[0], 1e-6)));
    await t.pumpWidget(const SizedBox());
  });

  test('the camera follows the drifted moon', () {
    final scene = CelestialScene.resolve(SkyState.at(_t0,
        latitudeDeg: greenwichDefaultLat, longitudeDeg: greenwichDefaultLng));
    expect(viewAzimuth(scene, driftRad: 0), viewAzimuth(scene));
    final d = siderealDriftRad(const Duration(minutes: 10));
    final moon = driftedDirection(scene.moonDir, scene.latitudeRad, d);
    if (moon.y > 0) {
      final (x, _, z) = worldToWater(moon, viewAzimuth(scene, driftRad: d));
      expect(x.abs(), lessThan(1e-9));
      expect(z, greaterThan(0));
    }
  });
}
