import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_camera.dart';
import 'package:illunis_client/sky/sky_painter.dart';
import 'package:illunis_client/sky/sky_shader.dart';
import 'package:illunis_client/sky/sky_state.dart';

const _w = 180, _h = 320;

// 2026-12-21, 21:00 UTC (UTC clock) at Warsaw: deep night, gibbous moon high in the south.
final _night = CelestialScene.resolve(
  SkyState.at(DateTime.utc(2026, 12, 21, 21),
      latitudeDeg: 52.23, longitudeDeg: 21.01),
);

Future<Uint8List> _paint(WidgetTester t, SkyShader? shader,
    {double azimuth = 0}) async {
  final bytes = await t.runAsync(() async {
    final rec = ui.PictureRecorder();
    SkyPainter(
      scene: _night,
      azimuthRad: azimuth,
      shader: shader,
      time: 1,
      devicePixelRatio: 1,
    ).paint(Canvas(rec), Size(_w.toDouble(), _h.toDouble()));
    final img = await rec.endRecording().toImage(_w, _h);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

List<int> _px(Uint8List b, int x, int y) {
  final o = (y * _w + x) * 4;
  return [b[o], b[o + 1], b[o + 2]];
}

int _brightAboveHorizon(Uint8List b, int threshold) {
  final horizon = (_h * kHorizonFraction).floor();
  var n = 0;
  for (var y = 0; y < horizon; y++) {
    for (var x = 0; x < _w; x++) {
      final p = _px(b, x, y);
      if (p[0] + p[1] + p[2] > threshold) n++;
    }
  }
  return n;
}

void main() {
  test('uniform table in sky.frag matches SkyShader.uniforms', () {
    final src = File('shaders/sky.frag').readAsStringSync();
    final decl = RegExp(r'^uniform\s+(float|vec2|vec3|vec4)\s+(\w+);\s*//\s*([\d,\-]+)',
        multiLine: true);
    const width = {'float': 1, 'vec2': 2, 'vec3': 3, 'vec4': 4};
    var next = 0;
    for (final m in decl.allMatches(src)) {
      final first = int.parse(RegExp(r'\d+').firstMatch(m.group(3)!)!.group(0)!);
      expect(first, next, reason: '${m.group(2)} documented index');
      next += width[m.group(1)]!;
    }
    expect(next, SkyShader.floatCount);
    final values = SkyShader.uniforms(
      scene: _night,
      camera: SkyCamera(size: const Size(100, 200), azimuthRad: 0.3),
      time: 2,
      pixelScale: 3,
    );
    expect(values.length, SkyShader.floatCount);
    expect(values[5], 0.3); // uAzimuth
    expect(values[6], _night.sunDir.x); // uSunDir.x
    expect(values[18], 2); // uTime
    expect(values[19], SkyShader.moonAngularRadius);
    expect(values[43], 3); // uPixelScale
  });

  testWidgets('fallback gradient draws a navy night sky with catalog stars',
      (t) async {
    final b = await _paint(t, null, azimuth: _night.trackAzimuthRad);
    final top = _px(b, 4, 4);
    expect(top[2], greaterThan(top[0])); // blue over red
    expect(_brightAboveHorizon(b, 120), greaterThan(5)); // stars drawn
    final ground = _px(b, _w ~/ 2, _h - 4);
    expect(ground[0] + ground[1] + ground[2], lessThan(60));
  });

  testWidgets('sky.frag compiles and renders a night with stars and moon',
      (t) async {
    final shader = await t.runAsync(SkyShader.load);
    expect(shader, isNotNull, reason: 'sky.frag did not load');
    final b = await _paint(t, shader, azimuth: _night.moonAzimuthRad);
    final top = _px(b, _w ~/ 2, 2);
    expect(top[2], greaterThanOrEqualTo(top[0])); // navy, not grey or black
    // The moon (enlarged ~3x, radius ~ focal * 0.014 px) is a bright disc.
    expect(_brightAboveHorizon(b, 450), greaterThan(4));
    shader!.dispose();
  });
}
