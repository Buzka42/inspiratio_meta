// A star drawn per pixel (SkyDetail) is a sharp disc a few screen pixels
// wide, where a baked texel spread over 3 to 7. Needs Impeller and Flutter
// GPU in the tester (flutter test --enable-impeller --enable-flutter-gpu);
// skipped otherwise.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

bool _gpuAvailable() {
  try {
    gpu.gpuContext;
    return true;
  } catch (_) {
    return false;
  }
}

Future<ui.Image> _darkSky() {
  const w = 256, h = 128;
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = 20;
    px[i * 4 + 1] = 25;
    px[i * 4 + 2] = 40;
    px[i * 4 + 3] = 255;
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

void main() {
  test('a per-pixel star is a sharp disc at the reflected direction', () async {
    final r = await GpuWaterRenderer.create(
        sky: await _darkSky(), texelBudget: 4096, asset: 'assets/water.shaderbundle');
    const w = 1080, h = 2400;
    r.resize(w, h);
    // Straight ahead at 60 degrees elevation: the screen centre for the
    // default 60 degree pitch on mirror-flat water.
    const e = 60 * math.pi / 180;
    r.setDetail(SkyDetail(
        stars: Float32List.fromList([0, math.sin(e), math.cos(e), 1, 2.0, 0])));
    final img = r.frame(0, time: 0, vignette: 0, detail: 0, stillness: 0)!;
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    int g(int x, int y) => b[(y * w + x) * 4 + 1];
    var peak = 0, px = 0, py = 0, lit = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = g(x, y);
        if (v > 60) lit++;
        if (v > peak) {
          peak = v;
          px = x;
          py = y;
        }
      }
    }
    // printOnFailure keeps the numbers for a failing run.
    printOnFailure('peak=$peak at ($px, $py) lit=$lit');
    // Reflectance near the screen centre is about 0.62, so white reads ~130.
    expect(peak, greaterThan(110));
    expect((px - w / 2).abs(), lessThan(3));
    expect((py - h / 2).abs(), lessThan(3));
    // Radius 2 px: about 13 px of disc; the glow stays under the threshold.
    expect(lit, inInclusiveRange(6, 24));
    expect(g(px + 5, py), lessThan(60));
  }, skip: !_gpuAvailable());
}
