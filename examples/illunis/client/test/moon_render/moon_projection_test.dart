import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/moon_manifest.dart';
import 'package:illunis_client/moon_render/moon_mesh.dart';
import 'package:illunis_client/moon_render/moon_projection.dart';
import 'package:illunis_client/moon_render/tile_loader.dart';

MoonManifest realManifest() {
  final r = parseMoonManifest(
    File('assets/moon/manifest.json').readAsStringSync(),
  );
  return (r as ManifestOk).manifest;
}

// Mare Crisium, centre near 17.0 N, 59.1 E (IAU / USGS gazetteer).
const crisiumLat = 17.0, crisiumLon = 59.1;
// Southern highlands, no mare (between Tycho and Mare Nectaris).
const highlandLat = -40.0, highlandLon = 20.0;

void main() {
  final m = realManifest();
  final def = m.defaultMap;
  final proj = MoonProjection(centre: const Offset(500, 500), radius: 400);

  group('lat/long to texture mapping', () {
    test('disc centre maps to the map centre', () {
      final ll = proj.unproject(const Offset(500, 500))!;
      expect(ll.$1, closeTo(0, 1e-9));
      expect(ll.$2, closeTo(0, 1e-9));
      final t = texelOnLevel(m, def, ll.$1, ll.$2);
      expect(t.dx, closeTo(2048, 1e-6));
      expect(t.dy, closeTo(1024, 1e-6));
    });

    test('top edge of the disc is the north pole, texture row 0', () {
      final ll = proj.unproject(const Offset(500, 100))!;
      expect(ll.$1, closeTo(90, 1e-6));
      expect(texelOnLevel(m, def, ll.$1, ll.$2).dy, closeTo(0, 1e-6));
      final p = proj.project(90, 37);
      expect(p.x, closeTo(500, 1e-6));
      expect(p.y, closeTo(100, 1e-6));
    });

    test('Mare Crisium lands east of centre and on the expected texel', () {
      final p = proj.project(crisiumLat, crisiumLon);
      expect(p.front, isTrue);
      final cl = math.cos(crisiumLat * math.pi / 180);
      expect(
        p.x,
        closeTo(500 + 400 * cl * math.sin(crisiumLon * math.pi / 180), 1e-6),
      );
      expect(
        p.y,
        closeTo(500 - 400 * math.sin(crisiumLat * math.pi / 180), 1e-6),
      );
      final back = proj.unproject(Offset(p.x, p.y))!;
      expect(back.$1, closeTo(crisiumLat, 1e-9));
      expect(back.$2, closeTo(crisiumLon, 1e-9));

      final t = texelOnLevel(m, def, crisiumLat, crisiumLon);
      expect(t.dx, closeTo((crisiumLon + 180) / 360 * 4096, 1e-6)); // 2720.4
      expect(t.dy, closeTo((90 - crisiumLat) / 180 * 2048, 1e-6)); // 830.6
      final tile = tileTexel(m, m.levels.first, crisiumLat, crisiumLon);
      expect(tile.file, 'tiles/L0_10_3.jpg');
      expect(tile.local.dx, closeTo(5440.9 - 10 * 512, 0.1));
      expect(tile.local.dy, closeTo(1661.2 - 3 * 512, 0.1));
    });

    test('projection round-trips with a rotated view', () {
      final p = MoonProjection(
        centre: const Offset(300, 300),
        radius: 250,
        longitudeDeg: 40,
        latitudeDeg: -25,
      );
      final c = p.unproject(const Offset(300, 300))!;
      expect(c.$1, closeTo(-25, 1e-9));
      expect(c.$2, closeTo(40, 1e-9));
      for (final (lat, lon) in [(10.0, 50.0), (-60.0, 20.0), (0.0, 90.0)]) {
        final s = p.project(lat, lon);
        expect(s.front, isTrue);
        final ll = p.unproject(Offset(s.x, s.y))!;
        expect(ll.$1, closeTo(lat, 1e-9));
        expect(ll.$2, closeTo(lon, 1e-9));
      }
    });

    testWidgets('bundled default map: Crisium texel is darker than highland', (
      tester,
    ) async {
      final lum = await tester.runAsync(() async {
        final image = await AssetMoonTileLoader().load(def.files.first);
        expect(image.width, 4096);
        expect(image.height, 2048);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        double mean(double lat, double lon) {
          final t = texelOnLevel(m, def, lat, lon);
          var sum = 0.0;
          for (var dy = -4; dy <= 4; dy++) {
            for (var dx = -4; dx <= 4; dx++) {
              final i =
                  ((t.dy.floor() + dy) * image.width + t.dx.floor() + dx) * 4;
              sum +=
                  bytes.getUint8(i) +
                  bytes.getUint8(i + 1) +
                  bytes.getUint8(i + 2);
            }
          }
          return sum / (81 * 3);
        }

        final r = (
          mean(crisiumLat, crisiumLon),
          mean(highlandLat, highlandLon),
        );
        image.dispose();
        return r;
      });
      expect(lum!.$1, lessThan(lum.$2 * 0.8), reason: 'crisium $lum');
    });
  });

  group('region mesh', () {
    test('whole map keeps only the near side, inside the disc', () {
      final mesh = buildRegionMesh(
        projection: proj,
        region: MapRegion.whole(m),
        imageWidth: 4096,
        imageHeight: 2048,
        bounds: const Rect.fromLTWH(0, 0, 1000, 1000),
        columns: 96,
        rows: 48,
      )!;
      // Near side is half the quads, plus the ring that straddles the limb.
      expect(mesh.triangleCount, greaterThan(96 * 48));
      expect(mesh.triangleCount, lessThan(96 * 48 * 2 * 0.6));
      for (var k = 0; k < mesh.positions.length; k += 2) {
        final d = math.sqrt(
          math.pow(mesh.positions[k] - 500, 2) +
              math.pow(mesh.positions[k + 1] - 500, 2),
        );
        expect(d, lessThanOrEqualTo(400 + 1e-3));
      }
    });

    test('far-side tile gives no mesh', () {
      final level = m.levels.first;
      // Column 0 spans lon -180..-157.5: the far side from lon 0.
      final mesh = buildRegionMesh(
        projection: proj,
        region: MapRegion.tile(m, level, 0, 3),
        imageWidth: 512,
        imageHeight: 512,
        bounds: const Rect.fromLTWH(0, 0, 1000, 1000),
      );
      expect(mesh, isNull);
    });
  });
}
