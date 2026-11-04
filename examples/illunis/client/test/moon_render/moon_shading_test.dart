import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/moon_disc.dart';
import 'package:illunis_client/moon/moon_manifest.dart';
import 'package:illunis_client/moon_render/moon_controller.dart';
import 'package:illunis_client/moon_render/moon_shading.dart';
import 'package:illunis_client/moon_render/tile_loader.dart';

import '../moon/moon_test_fixtures.dart';
import 'fake_loader.dart';

class _WhiteLoader implements MoonTileLoader {
  @override
  Future<ui.Image> load(String file) async => solidImage(64, 32, 0xFFFFFFFF);
}

(double, double, double) _n(double x, double y, double z) {
  final l = math.sqrt(x * x + y * y + z * z);
  return (x / l, y / l, z / l);
}

void main() {
  group('MoonLight', () {
    test('full, new and quarter moon from the phase', () {
      final full = MoonLight.fromPhase(0.3, 1);
      expect(full.z, closeTo(1, 1e-12));
      expect(MoonLight.fromPhase(0, 0).z, closeTo(-1, 1e-12));
      final q = MoonLight.fromPhase(0, 0.5);
      expect(q.x, closeTo(1, 1e-12));
      expect(q.z, closeTo(0, 1e-12));
      expect(MoonLight.fromPhase(1.1, 0.27).illumination, closeTo(0.27, 1e-12));
    });

    test('phase and world directions give the same light', () {
      // Moon due south, a little up; sun low in the west, behind.
      final moon = _n(0, 0.3, -1);
      final sun = _n(-1, 0.05, 0.4);
      const upWorld = (0.0, 1.0, 0.0);
      // MoonFrame: right = moon x up, up = right x moon.
      (double, double, double) cross(
              (double, double, double) a, (double, double, double) b) =>
          (a.$2 * b.$3 - a.$3 * b.$2, a.$3 * b.$1 - a.$1 * b.$3, a.$1 * b.$2 - a.$2 * b.$1);
      final right = _n(cross(moon, upWorld).$1, cross(moon, upWorld).$2, cross(moon, upWorld).$3);
      final upT = cross(right, moon);
      final exact = MoonLight.fromDirections(moon, sun, right, upT);
      final cosE = moon.$1 * sun.$1 + moon.$2 * sun.$2 + moon.$3 * sun.$3;
      final illum = (1 - cosE) / 2;
      final angle = math.atan2(
          -(sun.$1 * upT.$1 + sun.$2 * upT.$2 + sun.$3 * upT.$3),
          sun.$1 * right.$1 + sun.$2 * right.$2 + sun.$3 * right.$3);
      final fromPhase = MoonLight.fromPhase(angle, illum);
      expect(fromPhase.x, closeTo(exact.x, 1e-9));
      expect(fromPhase.y, closeTo(exact.y, 1e-9));
      expect(fromPhase.z, closeTo(exact.z, 1e-9));
    });
  });

  group('surface factor', () {
    test('full moon is flat and below white', () {
      final l = MoonLight.fromPhase(0, 1);
      final c = moonSurfaceFactor(0, 0, l);
      expect(c, lessThan(1));
      expect(c, greaterThan(0.8));
      expect(moonSurfaceFactor(0.6, 0.5, l), closeTo(c, 1e-9));
    });

    test('crescent limb rolls off below white', () {
      final l = MoonLight.fromPhase(0, 0.1);
      for (var u = 0.0; u <= 1.0; u += 0.01) {
        expect(moonSurfaceFactor(u, 0, l), lessThanOrEqualTo(moonPeak + moonEarthshine));
      }
      expect(moonSurfaceFactor(0.99, 0, l), greaterThan(0.85));
    });

    test('terminator is the same curve as moonDarkSide', () {
      const r = 100.0, c = Offset(0, 0);
      for (final (angle, illum) in [(0.4, 0.3), (2.0, 0.5), (-1.2, 0.8), (3.0, 0.12)]) {
        final dark = moonDarkSide(c, r, angle, illum);
        final l = MoonLight.fromPhase(angle, illum);
        var litArea = 0, total = 0;
        for (var j = -50; j <= 50; j++) {
          for (var i = -50; i <= 50; i++) {
            final u = i / 50, v = j / 50;
            if (u * u + v * v > 0.97) continue;
            total++;
            final f = moonSurfaceFactor(u, v, l);
            final isLit = f > moonEarthshine + 1e-9;
            if (isLit) litArea++;
            // Away from the edge the path and the shading agree.
            final near = [for (final d in const [Offset(3, 0), Offset(-3, 0), Offset(0, 3), Offset(0, -3)])
              dark.contains(Offset(u * r, v * r) + d)];
            if (near.every((e) => e)) expect(isLit, isFalse, reason: '$angle $illum ($u,$v)');
            if (near.every((e) => !e)) expect(isLit, isTrue, reason: '$angle $illum ($u,$v)');
          }
        }
        // Lit share of the disc area: (1 + cos a) / 2 = illumination.
        expect(litArea / total, closeTo(illum, 0.03));
      }
    });
  });

  test('halo fades to nothing at the outer edge and by day', () {
    final night = moonHaloPaint(
        centre: Offset.zero, radius: 100, outerRadius: 108, illumination: 1, dayness: 0);
    expect(night, isNotNull);
    expect(
        moonHaloPaint(centre: Offset.zero, radius: 100, outerRadius: 108, illumination: 1, dayness: 1),
        isNull);
  });

  testWidgets('painted disc: lit side bright, not white; dark side earthshine; soft halo', (tester) async {
    final px = await tester.runAsync(() async {
      final manifest = (parseMoonManifest(sampleManifestText()) as ManifestOk).manifest;
      final moon = MoonController(manifest: manifest, loader: _WhiteLoader());
      await moon.start();
      const size = 240, r = 100.0;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.drawColor(const Color(0xFF000000), BlendMode.src);
      // Quarter moon lit from the right.
      paintMoonDisc(canvas,
          moon: moon,
          centre: const Offset(120, 120),
          radius: r,
          sunAngle: 0,
          illumination: 0.5,
          dayness: 0);
      final img = await rec.endRecording().toImage(size, size);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int at(int x, int y) => bytes.getUint8((y * size + x) * 4);
      final out = (
        lit: at(180, 120),
        dark: at(60, 120),
        halo: at(120, 120 - 103),
        far: at(120, 120 - 115),
      );
      img.dispose();
      moon.dispose();
      return out;
    });
    expect(px!.lit, greaterThan(200));
    expect(px.lit, lessThan(255));
    expect(px.dark, lessThan(40));
    expect(px.halo, greaterThan(0));
    expect(px.halo, lessThan(40));
    expect(px.far, 0);
  });
}
