import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'celestial_scene.dart';
import 'sky_camera.dart';
import 'sky_shader.dart';
import 'star_field.dart';

/// Native-resolution atmosphere, then catalog points. No intermediate
/// image: limbs, grain and gradients are resolved at the display's density.
///
/// Ported from the original Illunis app without the weather pass.
class SkyPainter extends CustomPainter {
  SkyPainter({
    required this.scene,
    required this.azimuthRad,
    required this.shader,
    required this.time,
    required this.devicePixelRatio,
  });

  final ResolvedScene scene;
  final double azimuthRad;
  final SkyShader? shader;
  final double time;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide < 8) return;
    final camera = SkyCamera(size: size, azimuthRad: azimuthRad);
    final s = shader;
    if (s == null) {
      paintFallback(canvas, size, scene.dayness);
    } else {
      final fs = s.newShader();
      SkyShader.write(
        fs,
        scene: scene,
        camera: camera,
        time: time,
        pixelScale: devicePixelRatio,
      );
      canvas.drawRect(Offset.zero & size, Paint()..shader = fs);
    }
    paintCatalogStars(canvas, scene: scene, camera: camera, time: time);
  }

  /// Before the program is compiled, or on a GPU that refuses it: the same
  /// composition in plain gradients, so nothing is ever black.
  static void paintFallback(Canvas canvas, Size size, double dayness) {
    final horizon = size.height * kHorizonFraction;
    final zenith = Color.lerp(
      const Color(0xFF060A16),
      const Color(0xFF3B78C9),
      dayness,
    )!;
    final low = Color.lerp(
      const Color(0xFF0B1224),
      const Color(0xFFB7CDE8),
      dayness,
    )!;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, horizon),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, horizon), [
          zenith,
          low,
        ]),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, horizon, size.width, size.height - horizon),
      Paint()..color = const Color(0xFF0A0B0E),
    );
  }

  @override
  bool shouldRepaint(SkyPainter old) => true;
}
