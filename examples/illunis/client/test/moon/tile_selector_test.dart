import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/moon_manifest.dart';
import 'package:illunis_client/moon/moon_view.dart';
import 'package:illunis_client/moon/tile_selector.dart';

import 'moon_test_fixtures.dart';

/// Brute force: tiles under every 2nd pixel, by an independent
/// unprojection (view -> world).
Set<String> denseTruth(MoonLevel level, MoonView v, MoonScreen s) {
  const rad = math.pi / 180;
  final r = s.fitRadius * v.zoom;
  final lon0 = v.longitudeDeg * rad, lat0 = v.latitudeDeg * rad;
  final out = <String>{};
  for (var py = 0.0; py <= s.height; py += 2) {
    for (var px = 0.0; px <= s.width; px += 2) {
      final x = (px - s.width / 2) / r, y = (s.height / 2 - py) / r;
      if (x * x + y * y >= 1) continue;
      final z = math.sqrt(math.max(0.0, 1 - x * x - y * y));
      final wy = y * math.cos(lat0) + z * math.sin(lat0);
      final z1 = -y * math.sin(lat0) + z * math.cos(lat0);
      final wx = x * math.cos(lon0) + z1 * math.sin(lon0);
      final wz = -x * math.sin(lon0) + z1 * math.cos(lon0);
      final lat = math.asin(wy.clamp(-1.0, 1.0)) / rad;
      final lon = math.atan2(wx, wz) / rad;
      final col = (((lon + 180) / 360) % 1 * level.columns).floor().clamp(
        0,
        level.columns - 1,
      );
      final row = ((90 - lat) / 180 * level.rows).floor().clamp(
        0,
        level.rows - 1,
      );
      out.add(level.fileAt(col, row));
    }
  }
  return out;
}

void main() {
  final manifest =
      (parseMoonManifest(sampleManifestText()) as ManifestOk).manifest;
  final selector = TileSelector(manifest);
  const phone = MoonScreen(1080, 2400);
  final tiled = manifest.levels.single;

  test('max zoom is set by the 8K source', () {
    // 8192 * 1.25 / (2 * pi * 540)
    expect(selector.maxZoom(phone), closeTo(3.018, 1e-3));
    // A tiny screen never drops below 1x.
    expect(selector.maxZoom(const MoonScreen(1e5, 1e5)), 1.0);
  });

  test('zoomed-out view selects the default 4K map', () {
    final v = MoonView(maxZoom: selector.maxZoom(phone));
    final sel = selector.select(v, phone);
    expect(sel.level.isDefault, isTrue);
    expect(sel.level.width, 4096);
    expect(sel.files, ['default.jpg']);
  });

  test('coarsest level that meets the target', () {
    final v = MoonView(maxZoom: selector.maxZoom(phone))..pinchBy(1.4);
    expect(selector.levelFor(v, phone).isDefault, isTrue);
    v.pinchBy(1.2); // 1.68: 4K would be magnified past the slack
    expect(selector.levelFor(v, phone).level, 0);
  });

  test('zoomed-in view selects 8K tiles only for the visible region', () {
    final v = MoonView(maxZoom: selector.maxZoom(phone))..pinchBy(100);
    final sel = selector.select(v, phone);
    expect(sel.level.level, 0);
    expect(sel.level.width, 8192);

    final truth = denseTruth(tiled, v, phone);
    expect(sel.files.toSet().containsAll(truth), isTrue);
    expect(sel.files.length, lessThan(30));
    // Centre (0, 0) sits on the corner of columns 7/8 and rows 3/4.
    expect(sel.files, containsAll(['tiles/L0_7_3.jpg', 'tiles/L0_8_4.jpg']));
    // Far side and polar caps are not loaded.
    expect(sel.files, isNot(contains('tiles/L0_0_4.jpg')));
    expect(sel.files, isNot(contains('tiles/L0_15_4.jpg')));
    expect(sel.files, isNot(contains('tiles/L0_8_0.jpg')));
    expect(sel.files, isNot(contains('tiles/L0_8_7.jpg')));
    // Every selected tile has a visible point: within the visible box.
    for (final f in sel.files) {
      final m = RegExp(r'L0_(\d+)_(\d+)').firstMatch(f)!;
      expect(int.parse(m[1]!), inInclusiveRange(5, 10), reason: f);
      expect(int.parse(m[2]!), inInclusiveRange(1, 6), reason: f);
    }
  });

  test('panned view follows the centre', () {
    final v = MoonView(maxZoom: selector.maxZoom(phone))
      ..pinchBy(100)
      ..centreOn(90, 30);
    final sel = selector.select(v, phone);
    expect(sel.files.toSet().containsAll(denseTruth(tiled, v, phone)), isTrue);
    // lon 90 is column 12, lat 30 is row 2.
    expect(sel.files, contains('tiles/L0_12_2.jpg'));
    expect(sel.files, isNot(contains('tiles/L0_7_3.jpg')));
  });

  test('whole disc on the 8K grid skips the far side', () {
    final v = MoonView();
    final files = selector.visibleTiles(tiled, v, phone);
    expect(files.toSet().containsAll(denseTruth(tiled, v, phone)), isTrue);
    // Near side spans columns 4..11 (lon -90..90); limb tiles included.
    for (final f in files) {
      final c = int.parse(RegExp(r'L0_(\d+)_').firstMatch(f)![1]!);
      expect(c, inInclusiveRange(4, 11), reason: f);
    }
    // Polar rows wrap fully around and are partly visible.
    expect(files, contains('tiles/L0_4_0.jpg'));
    expect(files.length, 8 * 8);
  });
}
