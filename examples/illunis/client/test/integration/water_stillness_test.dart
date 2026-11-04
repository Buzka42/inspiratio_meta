// Option A water: uStillness 0 is a mirror (a loud voice and the walker do
// not move it), 1 keeps the earlier rough look. Synthetic sky only.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/widgets/water_pass.dart';

const _w = 144, _h = 256, _sw = 256, _sh = 128;

Uint8List _skyPixels() {
  final px = Uint8List(_sw * _sh * 4);
  for (var y = 0; y < _sh; y++) {
    for (var x = 0; x < _sw; x++) {
      final u = (x + 0.5) / _sw, v = (y + 0.5) / _sh;
      final i = (y * _sw + x) * 4;
      px[i] = (128 + 100 * math.sin(2 * math.pi * u * 6)).round();
      px[i + 1] = (30 + 300 * v).round().clamp(0, 255);
      px[i + 2] = (128 + 100 * math.cos(2 * math.pi * v * 5)).round();
      px[i + 3] = 255;
    }
  }
  return px;
}

double _meanDiff(Uint8List a, Uint8List b) {
  var s = 0;
  for (var i = 0; i < a.length; i++) {
    if (i % 4 != 3) s += (a[i] - b[i]).abs();
  }
  return s / (a.length * 3 / 4);
}

void main() {
  testWidgets('stillness scales every ripple together', (t) async {
    late ui.FragmentProgram program;
    late ui.Image sky;
    await t.runAsync(() async {
      program = await ui.FragmentProgram.fromAsset('shaders/water.frag');
      final buf = await ui.ImmutableBuffer.fromUint8List(_skyPixels());
      final desc = ui.ImageDescriptor.raw(buf,
          width: _sw, height: _sh, pixelFormat: ui.PixelFormat.rgba8888);
      sky = (await (await desc.instantiateCodec()).getNextFrame()).image;
    });

    Future<Uint8List> render(double stillness, double loudness, Offset walker) async {
      final key = GlobalKey();
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: _w.toDouble(),
              height: _h.toDouble(),
              child: WaterPass(
                  sky: sky,
                  walker: walker,
                  loudness: loudness,
                  vignette: 0,
                  stillness: stillness,
                  programLoader: () async => program),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 1300));
      return (await t.runAsync(() async {
        final img =
            await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
        final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        img.dispose();
        return d!.buffer.asUint8List();
      }))!;
    }

    const off = Offset(0.5, -4), near = Offset(0.5, 0.7);
    final calmQuiet = await render(0, 0, off);
    final calmLoud = await render(0, 1, near);
    final roughQuiet = await render(1, 0, off);
    final roughLoud = await render(1, 1, near);
    final calm = _meanDiff(calmQuiet, calmLoud);
    final rough = _meanDiff(roughQuiet, roughLoud);
    final calmVsRough = _meanDiff(calmQuiet, roughQuiet);
    debugPrint('loud vs quiet: stillness 0 mean=${calm.toStringAsFixed(2)}, '
        'stillness 1 mean=${rough.toStringAsFixed(2)}; calm vs rough ${calmVsRough.toStringAsFixed(2)}');
    expect(calm, lessThan(0.5));
    expect(rough, greaterThan(2));
    expect(calmVsRough, greaterThan(1));
  });
}
