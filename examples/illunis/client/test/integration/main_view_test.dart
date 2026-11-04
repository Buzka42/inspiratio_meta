// End-to-end checks of the main view: the real sky baked into the water's
// equirectangular image, the textured moon drawn into it and reflected where
// the hit test expects it, moon gestures, voice intents and the debug-only
// stillness slider. Synthetic data only (a flat grey moon map).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/illunis_root.dart';
import 'package:illunis_client/app/moon_focus.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/view_intents.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/core/mode_controller.dart';
import 'package:illunis_client/moon/moon_manifest.dart';
import 'package:illunis_client/moon_render/moon_controller.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_shader.dart';
import 'package:illunis_client/sky/sky_state.dart';
import 'package:illunis_client/widgets/water_pass.dart';

import '../moon/moon_test_fixtures.dart';
import '../moon_render/fake_loader.dart';

ResolvedScene sceneAt(DateTime t) => CelestialScene.resolve(
    SkyState.at(t, latitudeDeg: greenwichDefaultLat, longitudeDeg: greenwichDefaultLng));

/// First dark night hour in 2026 with a bright moon that option A's water
/// reflects comfortably (elevation 25..55 degrees).
DateTime moonNight() {
  for (var h = 0; h < 24 * 120; h++) {
    final t = DateTime.utc(2026, 1, 1).add(Duration(hours: h));
    final s = sceneAt(t);
    final moonAlt = s.moonDir.altitude * radToDeg;
    if (s.sunDir.altitude * radToDeg < -14 &&
        moonAlt > 25 &&
        moonAlt < 55 &&
        s.moonIllumination > 0.85) {
      return t;
    }
  }
  throw StateError('no moon night found');
}

MoonController fakeMoon() => MoonController(
    manifest: (parseMoonManifest(sampleManifestText()) as ManifestOk).manifest,
    loader: FakeLoader(immediate: true));

double luma(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
}

Future<Uint8List> rgba(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

void main() {
  final night = moonNight();
  final scene = sceneAt(night);
  final az = viewAzimuth(scene);

  testWidgets('the moon is drawn into the sky image and reflected where the hit test looks',
      (t) async {
    late ui.Image base, sky;
    late ui.FragmentProgram water;
    late Uint8List basePx, skyPx;
    const zoom = 6.0;
    await t.runAsync(() async {
      final moon = fakeMoon();
      await moon.start();
      base = await bakeBaseSky(
          scene: scene,
          azimuth: az,
          shader: await SkyShader.load(),
          config: const SkyBakeConfig(equirectWidth: 1024, focal: 160));
      sky = await composeSky(base, az, MoonBake.of(scene, moon, moonAngularRadius(zoom)));
      water = await ui.FragmentProgram.fromAsset('shaders/water.frag');
      basePx = await rgba(base);
      skyPx = await rgba(sky);
      moon.dispose();
    });
    expect(sky.width, 1024);
    expect(sky.height, 512);

    // In the sky image: a point inside the zoomed disc but outside the sky
    // shader's own (zoom 1) disc is dark before stage 2 and moon after.
    final f = scene.moonDir;
    final side = (f.cross(Vec3.up)).normalized;
    final probe = (f + side * math.tan(moonAngularRadius(3))).normalized;
    final (pu, pv) = equirectUv(probe, az);
    final px = (pu * 1024).floor(), py = (pv * 512).floor();
    final before = luma(basePx, 1024, px, py), after = luma(skyPx, 1024, px, py);
    debugPrint('sky image at 3 base radii from the moon: before=$before after=$after');
    expect(after, greaterThan(before + 25));
    final (mu, mv) = equirectUv(f, az);
    expect(mu, closeTo(0.5, 1e-9)); // the view faces the moon

    // Through option A's water at stillness 0: the reflection is where
    // reflectedScreenPoint says, and dark sky a few radii away.
    const w = 180, h = 400;
    final key = GlobalKey();
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: w.toDouble(),
            height: h.toDouble(),
            child: WaterPass(
                sky: sky,
                walker: const Offset(0.5, -4),
                vignette: 0,
                stillness: 0,
                programLoader: () async => water),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.byKey(const ValueKey('water-shader')), findsOneWidget);
    final out = (await t.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
      final px = await rgba(img);
      img.dispose();
      return px;
    }))!;
    const size = Size(180, 400);
    final p = reflectedScreenPoint(f, az, size, ReflectionOptics.analytic)!;
    final r = reflectedRadius(f, az, moonAngularRadius(zoom), size, ReflectionOptics.analytic);
    final atMoon = luma(out, w, p.dx.round(), p.dy.round());
    final away = luma(out, w, p.dx.round(), (p.dy + 3 * r + 6).round().clamp(0, h - 1));
    debugPrint('reflection at ${p.dx.toStringAsFixed(1)},${p.dy.toStringAsFixed(1)} '
        'r=${r.toStringAsFixed(1)}: moon=$atMoon away=$away');
    expect(atMoon, greaterThan(away + 25));
    base.dispose();
    sky.dispose();
  });

  Future<(AppController, MoonFocus, MoonController)> pumpRoot(WidgetTester t,
      {ValueNotifier<double>? stillness}) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final moon = fakeMoon();
    await t.runAsync(moon.start);
    final focus = MoonFocus(moon: moon, maxZoom: 12);
    final c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: FakeServerPort(),
        tts: SilentTts(),
        modes: ViewModeController(focus: focus));
    await t.pumpWidget(IllunisRoot(
      controller: c,
      focus: focus,
      now: night,
      stillness: stillness,
      loadSkyShader: false,
      waterProgramLoader: () => Future.error(StateError('no shader here')),
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
    ));
    await t.pump();
    return (c, focus, moon);
  }

  Future<void> pinch(WidgetTester t, Offset at, double from, double to) async {
    final a = await t.startGesture(at - Offset(from, 0), pointer: 1);
    final b = await t.startGesture(at + Offset(from, 0), pointer: 2);
    for (var i = 1; i <= 5; i++) {
      final d = from + (to - from) * i / 5;
      await a.moveTo(at - Offset(d, 0));
      await b.moveTo(at + Offset(d, 0));
      await t.pump();
    }
    await a.up();
    await b.up();
    await t.pump();
  }

  testWidgets('pinch on the moon reflection zooms it; elsewhere nothing happens', (t) async {
    final (c, focus, moon) = await pumpRoot(t);
    expect(c.mode, GraphicMode.reflection);
    const size = Size(360, 800);
    final p = reflectedScreenPoint(scene.moonDir, az, size, ReflectionOptics.analytic)!;

    final away = Offset(p.dx, p.dy > 400 ? 80 : 720);
    await pinch(t, away, 20, 60);
    expect(focus.zoom, 1);

    await pinch(t, p, 20, 60);
    expect(focus.zoom, closeTo(3, 0.2));

    // One finger on the moon turns it (selenographic centre moves).
    final lon = moon.view.longitudeDeg;
    final g = await t.startGesture(p, pointer: 7);
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(12, 0));
      await t.pump();
    }
    await g.up();
    expect(moon.view.longitudeDeg, isNot(closeTo(lon, 1e-6)));

    // Voice zoom and the mode switch go through the same controller.
    expect(c.handleUtterance('zoom out of the moon'), UtteranceOutcome.modeChanged);
    expect(focus.zoom, lessThan(3));
    c.handleUtterance('classic mode');
    await t.pump();
    expect(find.byKey(const ValueKey('classic-sky')), findsOneWidget);
    expect(find.byType(WaterPass), findsNothing);
    expect(find.byType(Text), findsNothing);
    c.handleUtterance('reset the moon');
    await t.pump();
    c.handleUtterance('reflection mode');
    await t.pump();
    expect(find.byType(WaterPass), findsOneWidget);
    focus.dispose();
    moon.dispose();
  });

  testWidgets('debug builds: a three-finger long press opens the stillness slider', (t) async {
    final still = ValueNotifier(0.04);
    final (_, focus, moon) = await pumpRoot(t, stillness: still);
    expect(find.byType(Slider), findsNothing);

    final gs = [
      for (final (i, o) in [const Offset(60, 300), const Offset(180, 320), const Offset(300, 300)]
          .indexed)
        await t.startGesture(o, pointer: 20 + i),
    ];
    await t.pump(const Duration(milliseconds: 800));
    for (final g in gs) {
      await g.up();
    }
    await t.pump();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('stillness 0.04'), findsOneWidget);

    await t.drag(find.byType(Slider), const Offset(120, 0));
    await t.pump();
    expect(still.value, greaterThan(0.2));
    // A changed value reaches the water widget.
    final wp = t.widget<WaterPass>(find.byType(WaterPass));
    expect(wp.stillness, still.value);
    focus.dispose();
    moon.dispose();
  });
}
