import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

/// Unit direction at elevation [e] and water-frame azimuth [a] (u = 0.5 + a / 2pi).
List<double> dir(double e, double a) => [math.sin(a) * math.cos(e), math.sin(e), math.cos(a) * math.cos(e)];

SkyDetail detail(List<List<double>> stars) =>
    SkyDetail(stars: Float32List.fromList([for (final s in stars) ...s]));

/// The cell water_surface.frag reads for direction [d] in [layer].
int cellIndex(StarGrid g, List<double> d, int layer) {
  final u = 0.5 + math.atan2(d[0], d[2]) / (2 * math.pi);
  final v = 0.5 - math.asin(d[1]) / math.pi;
  final c = (u * g.cols).floor() % g.cols;
  final r = (v * 2 * g.rows).floor().clamp(0, g.rows - 1);
  return ((layer * g.rows + r) * g.cols + c) * 4;
}

bool holds(StarGrid g, List<double> d, List<double> star) {
  for (var l = 0; l < g.layers; l++) {
    final i = cellIndex(g, d, l);
    if ((g.texels[i] - star[0]).abs() < 1e-6 && (g.texels[i + 1] - star[1]).abs() < 1e-6) return true;
  }
  return false;
}

void main() {
  const px = 1.2 / 2268; // phone: fov scale over physical height

  test('packing round-trips alpha, radius and tint', () {
    final (a, r, t) = StarGrid.unpack(StarGrid.pack(0.5, 2.25, 0.8));
    expect(a, closeTo(0.5, 1 / 255));
    expect(r, 2.25);
    expect(t, closeTo(0.8, 1 / 255));
    expect(StarGrid.pack(1, 15.9, 1), lessThan(1 << 24)); // exact in float32
  });

  test('every pixel within a star\'s reach finds it, at any elevation', () {
    for (final e in [0.1, 0.6, 1.2, 1.5, 1.565]) {
      for (final a in [-3.1, 0.0, 2.0]) {
        final s = [...dir(e, a), 0.8, 2.0, 0.5];
        final g = StarGrid.build(detail([s]), px);
        final reach = 3.9 * px; // radius 2 px plus 1.9 px of anti-aliasing
        for (var k = 0; k < 16; k++) {
          final th = k * math.pi / 8;
          final e2 = (e + reach * math.sin(th)).clamp(0.0, math.pi / 2 - 1e-6);
          final a2 = a + reach * math.cos(th) / math.cos(e);
          expect(holds(g, dir(e2, a2), s), isTrue, reason: 'e=$e a=$a th=$th');
        }
      }
    }
  });

  test('close pairs share cells through the second layer, brightest first', () {
    final bright = [...dir(0.8, 0.3), 0.9, 2.0, 0.0];
    final faint = [...dir(0.8, 0.3 + 2 * px / math.cos(0.8)), 0.2, 1.0, 1.0];
    final g = StarGrid.build(detail([faint, bright]), px);
    final i0 = cellIndex(g, dir(0.8, 0.3), 0), i1 = cellIndex(g, dir(0.8, 0.3), 1);
    expect(StarGrid.unpack(g.texels[i0 + 3]).$1, closeTo(0.9, 0.01));
    expect(StarGrid.unpack(g.texels[i1 + 3]).$1, closeTo(0.2, 0.01));
    expect(g.dropped, 0);
  });

  test('stars below the horizon and empty stars are skipped', () {
    final g = StarGrid.build(detail([[...dir(-0.2, 0), 1, 2, 0], [...dir(0.5, 0), 0, 2, 0]]), px);
    expect(g.placed, 0);
  });
}
