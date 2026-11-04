import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Listenable, ValueListenable;
import 'package:flutter/rendering.dart';

import '../sky/celestial_math.dart';
import '../sky/celestial_scene.dart';
import '../sky/sky_camera.dart';
import '../sky/sky_painter.dart';
import '../sky/sky_shader.dart';
import '../sky/star_field.dart';
import 'moon_disc.dart';
import 'moon_focus.dart';
import 'reflection_geometry.dart';

/// Screen disc of the moon in Classic mode (null when the camera cannot
/// project it), the sky turned [driftRad] past the scene.
(Offset, double)? classicMoonDisc(ResolvedScene scene, double azimuth, Size size, double rho,
    {double driftRad = 0}) {
  final cam = SkyCamera(size: size, azimuthRad: azimuth);
  final moon = driftedDirection(scene.moonDir, scene.latitudeRad, driftRad);
  final p = cam.project(moon);
  if (p == null) return null;
  final cz = moon.dot(cam.forward);
  return (p, rho * cam.focal * 2 / (1 + cz));
}

/// Writes the sun, moon, sidereal time and planets of [scene] turned by
/// [driftRad] over the uniforms [SkyShader.write] set, so sky.frag's discs
/// stay under the drifted stars and textured moon without a re-resolve.
void writeSkyDrift(ui.FragmentShader fs, ResolvedScene scene, double driftRad) {
  if (driftRad == 0) return;
  final lat = scene.latitudeRad;
  void dir(int slot, Vec3 v) {
    final d = driftedDirection(v, lat, driftRad);
    fs
      ..setFloat(slot, d.x)
      ..setFloat(slot + 1, d.y)
      ..setFloat(slot + 2, d.z);
  }

  dir(6, scene.sunDir);
  dir(9, scene.moonDir);
  fs.setFloat(12, scene.siderealRad + driftRad);
  for (var i = 0; i < scene.planets.length; i++) {
    dir(23 + 4 * i, scene.planets[i].dir);
  }
}

/// Classic mode: the sky (sky.frag and catalog stars, as SkyView draws it)
/// at screen resolution, with the textured moon over the shader's disc at
/// the zoom of [focus]. No water. [drift] is the sidereal turn since
/// [scene] was resolved; the sky turns with it and the camera follows the
/// drifted moon ([viewAzimuth]), repainting without a new scene.
class ClassicSkyPainter extends CustomPainter {
  ClassicSkyPainter({
    required this.scene,
    required this.shader,
    required this.focus,
    required this.devicePixelRatio,
    this.drift,
  }) : super(repaint: drift == null ? focus : Listenable.merge([focus, drift]));

  final ResolvedScene scene;
  final ValueListenable<double>? drift;
  final SkyShader? shader;
  final MoonFocus focus;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide < 8) return;
    final driftRad = drift?.value ?? 0;
    final azimuth = viewAzimuth(scene, driftRad: driftRad);
    final cam = SkyCamera(size: size, azimuthRad: azimuth);
    final s = shader;
    if (s == null) {
      SkyPainter.paintFallback(canvas, size, scene.dayness);
    } else {
      final fs = s.newShader();
      SkyShader.write(fs, scene: scene, camera: cam, time: 0, pixelScale: devicePixelRatio);
      writeSkyDrift(fs, scene, driftRad);
      canvas.drawRect(Offset.zero & size, ui.Paint()..shader = fs);
    }
    paintCatalogStars(canvas, scene: scene, camera: cam, time: 0, driftRad: driftRad);

    final moon = focus.moon;
    final moonDir = driftedDirection(scene.moonDir, scene.latitudeRad, driftRad);
    if (moon == null || moon.defaultImage == null || moonDir.y < -0.02) return;
    final disc = classicMoonDisc(scene, azimuth, size, focus.angularRadius, driftRad: driftRad);
    if (disc == null) return;
    final frame = MoonFrame(moonDir, fallbackForward: cam.forward);
    final sunDir = driftedDirection(scene.sunDir, scene.latitudeRad, driftRad);
    // A hair larger than the shader's disc so its anti-aliased rim is covered.
    final r = disc.$2 * 1.04;
    if (!(Offset.zero & size).inflate(r).contains(disc.$1)) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height * kHorizonFraction));
    paintMoonDisc(canvas,
        moon: moon,
        centre: disc.$1,
        radius: math.max(r, 1),
        sunAngle: frame.sunAngle(sunDir),
        illumination: scene.moonIllumination,
        dayness: scene.dayness);
    canvas.restore();
  }

  @override
  bool shouldRepaint(ClassicSkyPainter old) =>
      old.scene != scene || old.drift != drift || old.shader != shader ||
      old.devicePixelRatio != devicePixelRatio;
}
