import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// Loads shaders/caption_dissolve.frag once per process. A failed load is
/// remembered so captions fall back to a plain fade without retrying.
class CaptionDissolveShader {
  CaptionDissolveShader._();

  static const String assetKey = 'shaders/caption_dissolve.frag';

  /// Float slots written by [CaptionDissolvePainter]; matches the uniform
  /// table at the top of caption_dissolve.frag.
  static const int floatCount = 4;

  static Future<ui.FragmentProgram?>? _loading;

  static Future<ui.FragmentProgram?> load() =>
      _loading ??= ui.FragmentProgram.fromAsset(assetKey).then<ui.FragmentProgram?>(
        (p) => p,
        onError: (Object e, StackTrace _) {
          debugPrint('caption_dissolve_unavailable (${e.runtimeType})');
          return null;
        },
      );

  /// Uniform values in slot order. Pure, so tests can check the layout.
  static List<double> uniforms(Size size, double progress, double seed) =>
      [size.width, size.height, progress.clamp(0.0, 1.0), seed];
}

/// Draws the captured caption [image] through the dissolve shader over the
/// full paint rect at [progress] (0 intact, 1 gone).
class CaptionDissolvePainter extends CustomPainter {
  CaptionDissolvePainter({
    required this.shader,
    required this.image,
    required this.progress,
    required this.seed,
  });

  final ui.FragmentShader shader;
  final ui.Image image;
  final double progress;
  final double seed;

  @override
  void paint(Canvas canvas, Size size) {
    final u = CaptionDissolveShader.uniforms(size, progress, seed);
    for (var i = 0; i < u.length; i++) {
      shader.setFloat(i, u[i]);
    }
    shader.setImageSampler(0, image, filterQuality: ui.FilterQuality.low);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(CaptionDissolvePainter old) =>
      old.progress != progress || old.image != image || old.seed != seed;
}
