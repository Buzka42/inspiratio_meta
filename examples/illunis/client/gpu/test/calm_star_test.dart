// Near-calm water must not blur a 1-texel star away. Needs Impeller and
// Flutter GPU in the tester (flutter test --enable-impeller --enable-flutter-gpu);
// skipped otherwise.
import 'dart:async';
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

const _sw = 4096, _sh = 2048; // the bake size: the blur taps sit about 1 texel apart

/// Dark sky with one white texel where the screen centre reflects
/// (azimuth 0, elevation 60 degrees for the default 60 degree pitch).
Future<ui.Image> _starSky() {
  final px = Uint8List(_sw * _sh * 4);
  for (var i = 0; i < _sw * _sh; i++) {
    px[i * 4] = 20;
    px[i * 4 + 1] = 25;
    px[i * 4 + 2] = 40;
    px[i * 4 + 3] = 255;
  }
  final o = ((_sh * (0.5 - 60 / 180)).floor() * _sw + _sw ~/ 2) * 4;
  px[o] = px[o + 1] = px[o + 2] = 255;
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, _sw, _sh, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

Future<int> _peak(GpuWaterRenderer r, double stillness) async {
  final img = r.frame(0, time: 0, vignette: 0, detail: 0, stillness: stillness)!;
  final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  var peak = 0;
  for (var i = 0; i < b.length; i += 4) {
    if (b[i + 1] > peak) peak = b[i + 1];
  }
  return peak;
}

void main() {
  test('the near-calm default keeps a 1-texel star as bright as a mirror', () async {
    final sky = await _starSky();
    Future<int> peakAt(double s) async {
      final r = await GpuWaterRenderer.create(
          sky: sky, texelBudget: 4096, asset: 'assets/water.shaderbundle');
      r.resize(1080, 2400); // phone size: a sky texel spans several pixels
      return _peak(r, s);
    }

    final mirror = await peakAt(0);
    final calm = await peakAt(0.04);
    expect(mirror, greaterThan(120)); // the star is on screen
    // The old fixed 0.4 centre weight left 0.79 of the peak here.
    expect(calm, greaterThan(mirror * 0.95));
  }, skip: !_gpuAvailable());
}
