import 'dart:typed_data';
import 'dart:ui' as ui;

import 'moon_projection.dart';

/// Triangle mesh that maps one map image onto the moon disc.
class MoonMesh {
  const MoonMesh(this.positions, this.texCoords, this.indices);

  /// x, y pairs in canvas pixels.
  final Float32List positions;

  /// x, y pairs in image pixels.
  final Float32List texCoords;
  final Uint16List indices;

  int get triangleCount => indices.length ~/ 3;

  ui.Vertices toVertices() => ui.Vertices.raw(
    ui.VertexMode.triangles,
    positions,
    textureCoordinates: texCoords,
    indices: indices,
  );
}

/// Builds a lon/lat grid over [region], projects it, and drops quads that
/// are fully on the far side or outside [bounds]. Returns null when
/// nothing is visible. Texture coordinates are linear in lon/lat, which is
/// exact for an equirectangular image; the sphere curvature comes from the
/// projected vertex positions.
MoonMesh? buildRegionMesh({
  required MoonProjection projection,
  required MapRegion region,
  required double imageWidth,
  required double imageHeight,
  required ui.Rect bounds,
  int columns = 8,
  int rows = 8,
}) {
  assert(columns > 0 && rows > 0, 'grid must be positive');
  final stride = columns + 1;
  assert(stride * (rows + 1) <= 65536, 'grid too fine for 16-bit indices');
  final n = stride * (rows + 1);
  final pos = Float32List(n * 2);
  final tex = Float32List(n * 2);
  final front = List<bool>.filled(n, false);
  for (var j = 0; j <= rows; j++) {
    final lat = region.northDeg - region.spanLatDeg * j / rows;
    for (var i = 0; i <= columns; i++) {
      final lon = region.westDeg + region.spanLonDeg * i / columns;
      final k = j * stride + i;
      final p = projection.project(lat, lon);
      pos[2 * k] = p.x;
      pos[2 * k + 1] = p.y;
      front[k] = p.front;
      tex[2 * k] = imageWidth * i / columns;
      tex[2 * k + 1] = imageHeight * j / rows;
    }
  }
  final idx = <int>[];
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < columns; i++) {
      final a = j * stride + i, b = a + 1, c = a + stride, d = c + 1;
      if (!(front[a] || front[b] || front[c] || front[d])) continue;
      if (!_overlaps(pos, [a, b, c, d], bounds)) continue;
      idx.addAll([a, b, c, b, d, c]);
    }
  }
  if (idx.isEmpty) return null;
  return MoonMesh(pos, tex, Uint16List.fromList(idx));
}

bool _overlaps(Float32List pos, List<int> ks, ui.Rect r) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final k in ks) {
    final x = pos[2 * k], y = pos[2 * k + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return maxX >= r.left && minX <= r.right && maxY >= r.top && minY <= r.bottom;
}
