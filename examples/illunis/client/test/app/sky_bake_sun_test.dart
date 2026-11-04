import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_shader.dart';
import 'package:illunis_client/sky/sky_state.dart';

// Warsaw, 2026-10-24 13:00 CEST: the sun about 25 degrees up.
final _scene = CelestialScene.resolve(
    SkyState.at(DateTime.utc(2026, 10, 24, 11), latitudeDeg: 52.2, longitudeDeg: 21.0));

double _luma(Uint8List b, int w, int x, int y) {
  final o = (y * w + x) * 4;
  return (0.2126 * b[o] + 0.7152 * b[o + 1] + 0.0722 * b[o + 2]) / 255;
}

/// Brightest texel within 2 of (x, y), and the median 5-8 texels out (the
/// disc is under 2 texels wide here, its Mie glow much wider).
(double, double) _peakAndRing(Uint8List b, int w, int h, int x, int y) {
  var peak = 0.0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      final l = _luma(b, w, (x + dx) % w, (y + dy).clamp(0, h - 1));
      if (l > peak) peak = l;
    }
  }
  final ring = <double>[];
  for (var dy = -8; dy <= 8; dy++) {
    for (var dx = -8; dx <= 8; dx++) {
      final r2 = dx * dx + dy * dy;
      if (r2 < 25 || r2 > 64) continue;
      ring.add(_luma(b, w, (x + dx) % w, (y + dy).clamp(0, h - 1)));
    }
  }
  ring.sort();
  return (peak, ring[ring.length ~/ 2]);
}

/// The per-pixel bake leaves the sun disc to the water (sky.frag uSunRadius
/// 0), keeping the glow; the baked path (option A) keeps it.
void main() {
  testWidgets('per-pixel bake has no sun disc, the baked path does', (t) async {
    expect(_scene.sunAltitudeRad * radToDeg, inInclusiveRange(15, 35));
    final shader = await t.runAsync(SkyShader.load);
    expect(shader, isNotNull);
    final az = viewAzimuth(_scene);
    const cfg = SkyBakeConfig(equirectWidth: 2048, focal: 350);
    final ew = cfg.equirectWidth, eh = cfg.equirectHeight;
    Future<Uint8List> bake(bool perPixel) async => (await t.runAsync(() async {
          final img = await bakeBaseSky(
              scene: _scene, azimuth: az, shader: shader, config: cfg, perPixelDetail: perPixel);
          final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          img.dispose();
          return d!.buffer.asUint8List();
        }))!;
    final baked = await bake(false), perPixel = await bake(true);

    final (u, v) = equirectUv(_scene.sunDir, az);
    final x = (u * ew).floor(), y = (v * eh).floor();
    final (bPeak, bRing) = _peakAndRing(baked, ew, eh, x, y);
    final (pPeak, pRing) = _peakAndRing(perPixel, ew, eh, x, y);
    // Baked: a saturated disc well above its glow.
    expect(bPeak, greaterThan(0.97));
    expect(bPeak - bRing, greaterThan(0.1));
    // Per pixel: no disc, only the smooth glow, which is unchanged.
    expect(pPeak - pRing, lessThan(0.06), reason: 'peak $pPeak ring $pRing');
    expect((pRing - bRing).abs(), lessThan(0.02));
  });
}
