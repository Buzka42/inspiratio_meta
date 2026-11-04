// Runs the real Flutter GPU passes. Needs Impeller and Flutter GPU in the
// tester, so run with:
//   flutter test --enable-impeller --enable-flutter-gpu
// Without those flags every test here is skipped (plain `flutter test`).
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

const _sw = 256, _sh = 128;

// Smooth synthetic sky: red with azimuth, green and blue with elevation.
(double, double, double) _skyFn(double u, double v) => (
      0.5 + 0.35 * math.sin(2 * math.pi * u),
      0.1 + 0.8 * v,
      0.5 + 0.4 * math.cos(2 * math.pi * v * 1.5),
    );

Future<ui.Image> _sky() {
  final px = Uint8List(_sw * _sh * 4);
  for (var y = 0; y < _sh; y++) {
    for (var x = 0; x < _sw; x++) {
      final (r, g, b) = _skyFn((x + 0.5) / _sw, (y + 0.5) / _sh);
      final i = (y * _sw + x) * 4;
      px[i] = (r * 255).round();
      px[i + 1] = (g * 255).round();
      px[i + 2] = (b * 255).round();
      px[i + 3] = 255;
    }
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, _sw, _sh, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Raw RGBA bytes, rows top to bottom as Flutter displays the image.
Future<Uint8List> _rgba(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

Future<Float32List> _rgbaF(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128))!.buffer.asFloat32List();

/// What water_surface.frag paints for a mirror-flat surface (no sim, no
/// analytic detail, vignette off).
(double, double, double) _flat(WaterCamera cam, double u, double v, double aspect) {
  final (dx, dy, dz) = cam.viewRay(ui.Offset(u, v), aspect);
  final ry = math.max(-dy, 0.01);
  final l = math.sqrt(dx * dx + ry * ry + dz * dz);
  final su = 0.5 + math.atan2(dx / l, dz / l) / (2 * math.pi);
  final sv = 0.5 - math.asin(ry / l) / math.pi;
  final (r, g, b) = _skyFn(su, sv);
  final refl = 0.62 + 0.38 * math.pow(1 - (-dy).clamp(0.0, 1.0), 3);
  double mix(double a, double b) => a + (b - a) * refl;
  return (mix(0.02, r * 0.92), mix(0.05, g * 0.97), mix(0.08, b));
}

void main() {
  // No TestWidgetsFlutterBinding here: its fake clock stalls GPU readbacks.
  final skip = !_gpuAvailable();

  Future<GpuWaterRenderer> make({int budget = 4096}) async {
    // A package's own tests see its assets without the packages/ prefix.
    return GpuWaterRenderer.create(sky: await _sky(), texelBudget: budget, asset: 'assets/water.shaderbundle');
  }

  test('GPU sim step matches the CPU reference', () async {
    final r = await make();
    r.resize(90, 160);
    final (w, h) = r.simSize;
    const drop = Drop(13, 21, 4, 0.8); // off-centre: a flipped axis would show
    var cpu = stepHeightField(HeightField(w, h), r.wave, const [drop]);
    r.debugStep(const [drop]);
    for (var i = 0; i < 40; i++) {
      cpu = stepHeightField(cpu, r.wave);
      r.debugStep(const []);
    }
    final px = await _rgbaF(r.debugSimImage());
    var worst = 0.0, energy = 0.0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final g = px[(y * w + x) * 4];
        worst = math.max(worst, (g - cpu.at(x, y)).abs());
        energy += g * g;
      }
    }
    expect(energy, greaterThan(0.01)); // the wave is there
    expect(worst, lessThan(4e-3)); // half-float storage vs float32 reference
  }, skip: skip);

  test('a calm surface reflects the sky with the expected orientation', () async {
    final r = await make();
    const w = 72, h = 128;
    r.resize(w, h);
    final img = r.frame(0, time: 0, vignette: 0, detail: 0)!;
    expect(img.width, w);
    expect(img.height, h);
    final px = await _rgba(img);
    var worst = 0.0;
    for (final (u, v) in [(0.5, 0.05), (0.5, 0.5), (0.5, 0.95), (0.1, 0.3), (0.9, 0.7)]) {
      final x = (u * w).floor(), y = (v * h).floor();
      final (er, eg, eb) = _flat(r.camera, (x + 0.5) / w, (y + 0.5) / h, w / h);
      final i = (y * w + x) * 4;
      for (final (got, want) in [(px[i], er), (px[i + 1], eg), (px[i + 2], eb)]) {
        worst = math.max(worst, (got / 255 - want).abs());
      }
    }
    expect(worst, lessThan(0.03));
  }, skip: skip);

  test('drops and the walker ripple the rendered surface; frames stay finite', () async {
    final r = await make(budget: 65536);
    const w = 90, h = 160;
    r.resize(w, h);
    final calm = await _rgba(r.frame(0, time: 0, vignette: 0, detail: 0)!);
    // frame() returns null while maxFramesInFlight frames are on the GPU, so
    // pace like a display would: yield until the next frame is accepted.
    ui.Image? img;
    var shown = 0;
    while (shown < 90) {
      final next = r.frame(1 / 60, time: shown / 60, loudness: 1, vignette: 0, detail: 0);
      if (next == null) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        continue;
      }
      img?.dispose();
      img = next;
      shown++;
    }
    final rough = await _rgba(img!);
    var changed = 0;
    for (var i = 0; i < calm.length; i += 4) {
      if ((calm[i] - rough[i]).abs() + (calm[i + 1] - rough[i + 1]).abs() > 2) changed++;
    }
    expect(changed, greaterThan(w * h * 0.01));
    final sim = await _rgbaF(r.debugSimImage());
    expect(sim.every((v) => v.isFinite), isTrue);
    expect(sim.any((v) => v.abs() > 1e-3), isTrue);
  }, skip: skip);
}
