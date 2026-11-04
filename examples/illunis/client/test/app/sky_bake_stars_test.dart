import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/reflection_geometry.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_shader.dart';
import 'package:illunis_client/sky/sky_state.dart';
import 'package:illunis_client/sky/star_catalog.dart';
import 'package:illunis_client/sky/star_field.dart';

// The phone check scene: Warsaw, 2026-10-24 23:00 CEST, a 0.98 moon at 46 degrees.
final _scene = CelestialScene.resolve(
    SkyState.at(DateTime.utc(2026, 10, 24, 21), latitudeDeg: 52.2, longitudeDeg: 21.0));

double _luma(Uint8List b, int w, int x, int y) {
  final o = (y * w + x) * 4;
  return (0.2126 * b[o] + 0.7152 * b[o + 1] + 0.0722 * b[o + 2]) / 255;
}

/// Brightest texel within 1 texel of (x, y), and the median sky 6-10 texels out.
(double, double) _peakAndSky(Uint8List b, int w, int h, int x, int y) {
  var peak = 0.0;
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      final l = _luma(b, w, (x + dx) % w, (y + dy).clamp(0, h - 1));
      if (l > peak) peak = l;
    }
  }
  final ring = <double>[];
  for (var dy = -10; dy <= 10; dy += 4) {
    for (var dx = -10; dx <= 10; dx += 4) {
      if (dx.abs() < 6 && dy.abs() < 6) continue;
      ring.add(_luma(b, w, (x + dx) % w, (y + dy).clamp(0, h - 1)));
    }
  }
  ring.sort();
  return (peak, ring[ring.length ~/ 2]);
}

/// The stars must survive the bake at its real size. They used to be drawn
/// into the stereographic picture and lost most of their contrast in its
/// resample to equirect (a mag 1.8 star 0.023 above the moonlit sky).
void main() {
  testWidgets('bright stars stand out of the moonlit sky in the bake', (t) async {
    final shader = await t.runAsync(SkyShader.load);
    expect(shader, isNotNull);
    final az = viewAzimuth(_scene);
    const cfg = SkyBakeConfig();
    final ew = cfg.equirectWidth, eh = cfg.equirectHeight;
    final bytes = (await t.runAsync(() async {
      final img = await bakeBaseSky(scene: _scene, azimuth: az, shader: shader, config: cfg);
      final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return d!.buffer.asUint8List();
    }))!;

    final weak = <String>[];
    var bright = 0, faint = 0, faintSeen = 0;
    for (var i = 0; i < kStarCount; i++) {
      final s = catalogStarAt(i);
      if (s.vMag > 4) break;
      final dir = catalogStarDirection(s, _scene.siderealRad, _scene.latitudeRad);
      if (dir.altitude < 10 * degToRad) continue;
      final (u, v) = equirectUv(dir, az);
      final (peak, sky) = _peakAndSky(bytes, ew, eh, (u * ew).floor(), (v * eh).floor());
      if (sky < 0.06) continue; // outside the sky the water reflects (fill colour)
      if (s.vMag <= 1.9) {
        bright++;
        if (peak < sky + 0.08) weak.add('#$i mag ${s.vMag} peak $peak sky $sky');
      } else if (s.vMag >= 3) {
        faint++;
        if (peak > sky + 0.02) faintSeen++;
      }
    }
    expect(bright, greaterThan(5));
    expect(weak, isEmpty);
    // Magnitude 3-4 stars keep a visible step over the sky, apart from those
    // in the moon's glare.
    expect(faintSeen, greaterThan(faint ~/ 2));
  });
}
