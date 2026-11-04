import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/voice/voice_session.dart';
import 'package:illunis_gpu/illunis_gpu.dart';
import 'package:illunis_client/app/water_port.dart';
import 'package:illunis_client/widgets/water_pass.dart';

import '../moon_render/fake_loader.dart';

void main() {
  test('the water is always the high-resolution GPU view (option B)', () {
    expect(waterPort(), isA<GpuWaterPort>());
  });

  testWidgets('option B that cannot start draws option A and reports its camera', (t) async {
    final port = GpuWaterPort(factory: (_, _) => Future.error(StateError('no gpu in tests')));
    expect(port.optics.value, ReflectionOptics.analytic);
    final sky = solidImage(64, 32);
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: port.build(WaterInputs(sky: sky, stillness: 0.3)),
    ));
    await t.pump();
    await t.pump();
    expect(port.optics.value, ReflectionOptics.analytic);
    // The bake must hold the stars and moon again once B has given up.
    expect(port.drawsSkyDetail, isFalse);
    final a = t.widget<WaterPass>(find.byType(WaterPass));
    expect(a.stillness, 0.3);
    sky.dispose();
  });

  testWidgets('option A hands the sun to its glint', (t) async {
    const sun = SkySun(
        dir: (0, 0.5, 0.866), angularRadius: 0.00465, colour: (1, 0.9, 0.8), intensity: 0.9,
        dayFade: 1);
    final sky = solidImage(64, 32);
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: const AnalyticWaterPort().build(WaterInputs(sky: sky, sun: sun)),
    ));
    expect(t.widget<WaterPass>(find.byType(WaterPass)).sun, sun);
    sky.dispose();
  });

  testWidgets('option B hands the day sun and clouds to the GPU water', (t) async {
    final pending = Completer<GpuWaterRenderer>(); // never starts: no GPU in tests
    final port = GpuWaterPort(factory: (_, _) => pending.future);
    const sun = SkySun(
        dir: (0, 0.5, 0.866), angularRadius: 0.00465, colour: (1, 0.9, 0.8), intensity: 0.9,
        dayFade: 1);
    const clouds = SkyClouds(windVelocity: (4, 0), tier: 1);
    final sky = solidImage(64, 32);
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: port.build(WaterInputs(sky: sky, sun: sun, clouds: clouds)),
    ));
    final g = t.widget<GpuWater>(find.byType(GpuWater));
    expect(g.sun, sun);
    expect(g.clouds, same(clouds));
    sky.dispose();
  });

  group('voice ripples', () {
    late double now;
    late RippleSources rip;
    setUp(() {
      now = 10;
      rip = RippleSources(clock: () => now);
    });

    test('a ripple starts at age 0 with its strength in slots 14-15', () {
      expect(rip.uniforms(), RippleSources.silent);
      rip.start(0.6);
      expect(rip.uniforms(), [0, 0.6, 0, 0, 0, 0, 0, 0]);
      now += 0.5;
      final u = rip.uniforms();
      expect(u[0], closeTo(0.5, 1e-9));
      expect(u[1], closeTo(0.6 * 0.64, 1e-9)); // (1 - 0.5 / 2.5)^2
    });

    test('a ripple fades out and is gone after its life', () {
      rip.start(1);
      now += RippleSources.life * 0.5;
      expect(rip.uniforms()[1], closeTo(0.25, 1e-9));
      now += RippleSources.life * 0.5 - 1e-3;
      expect(rip.uniforms()[1], lessThan(1e-6));
      now += 2e-3;
      expect(rip.uniforms(), RippleSources.silent);
      expect(rip.live, isEmpty);
    });

    test('at most four sources; a fifth replaces the oldest', () {
      for (var i = 0; i < 5; i++) {
        rip.start(0.2 * (i + 1));
        now += 0.1;
      }
      expect(rip.live.map((r) => r.id), [2, 3, 4, 5]);
      final u = rip.uniforms();
      expect(u.length, 8);
      expect(u[0], closeTo(0.4, 1e-9)); // ripple 2, started 0.4 s ago
      expect(u[6], closeTo(0.1, 1e-9)); // ripple 5, the newest
      expect(u[7], closeTo(1.0 * RippleSources.envelope(0.1), 1e-9));
    });

    test('each turn into listening starts one ripple, nothing else does', () {
      final c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: FakeServerPort(),
        tts: SilentTts(),
      );
      var level = 0.0;
      final feed = VoiceRippleFeed(c, rip, level: () => level);
      c.dispatch(const WakeWordHeard());
      expect(c.voice, VoiceState.listening);
      expect(rip.live.map((r) => r.strength), [0.6]); // no mic level: fixed
      c.dispatch(const UserSpeechStarted()); // stays listening
      expect(rip.live, hasLength(1));
      c.dispatch(const UserSpeechEnded('')); // back to idle
      level = 1;
      c.dispatch(const WakeWordHeard());
      expect(rip.live.map((r) => r.strength), [0.6, 1.0]); // follows the level
      feed.dispose();
      c.dispatch(const UserSpeechEnded(''));
      c.dispatch(const WakeWordHeard());
      expect(rip.live, hasLength(2));
    });

    test('option B gets one centre drop per new ripple', () {
      const cam = WaterCamera();
      final s = VoiceDropScheduler(rip, cam, () => 0.5);
      const w = 400, h = 600;
      final domain = cam.simDomain(0.5);
      final cellWorld = domain.width / w;
      final centre = worldToCell(cam.planeHit(const Offset(0.5, 0.5), 0.5)!, domain, w, h);
      // Walker off the water: only scheduled ambient drops, if any.
      List<Drop> step() => s.next(1 / 120, null, 0, w, h, cellWorld);
      bool atCentre(Drop d) => d.x == centre.dx && d.y == centre.dy;
      expect(step().where(atCentre), isEmpty);
      rip.start(0.5);
      final drops = step().where(atCentre).toList();
      expect(drops, hasLength(1));
      expect(drops.single.strength, closeTo(-VoiceDropScheduler.depth * 0.5, 1e-9));
      expect(drops.single.radius, closeTo(VoiceDropScheduler.radius / cellWorld, 1e-9));
      expect(step().where(atCentre), isEmpty); // not repeated
      for (var i = 0; i < 6; i++) {
        rip.start(1);
      }
      final burst = step();
      expect(burst.length, lessThanOrEqualTo(maxDropsPerStep));
      expect(burst.where(atCentre), hasLength(RippleSources.maxRipples));
    });

    testWidgets('option A draws its own ripples; option B shares its own with the fallback', (
      t,
    ) async {
      final sky = solidImage(64, 32);
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: const AnalyticWaterPort().build(WaterInputs(sky: sky)),
        ),
      );
      expect(t.widget<WaterPass>(find.byType(WaterPass)).ripples, isNotNull);
      final port = GpuWaterPort(factory: (_, _) => Future.error(StateError('no gpu in tests')));
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: port.build(WaterInputs(sky: sky)),
        ),
      );
      await t.pump();
      await t.pump();
      expect(t.widget<WaterPass>(find.byType(WaterPass)).ripples, same(port.ripples));
      sky.dispose();
    });
  });
}
