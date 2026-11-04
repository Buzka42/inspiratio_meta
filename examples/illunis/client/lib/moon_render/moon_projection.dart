import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../moon/moon_manifest.dart';

const _rad = math.pi / 180;

/// A point of the moon sphere drawn on screen.
class ProjectedPoint {
  const ProjectedPoint(this.x, this.y, {required this.front});
  final double x, y;

  /// False when the point is on the far side; [x], [y] are then clamped
  /// to the limb.
  final bool front;
}

/// Orthographic projection of the moon sphere onto a disc.
///
/// Same convention as TileSelector in lib/moon: world lon 0, lat 0 faces
/// the viewer, east longitude is to the right, north is up. The view
/// centre (lon0, lat0) is the selenographic point under the disc centre.
class MoonProjection {
  MoonProjection({
    required this.centre,
    required this.radius,
    double longitudeDeg = 0,
    double latitudeDeg = 0,
  }) : _sinLon = math.sin(longitudeDeg * _rad),
       _cosLon = math.cos(longitudeDeg * _rad),
       _sinLat = math.sin(latitudeDeg * _rad),
       _cosLat = math.cos(latitudeDeg * _rad);

  final Offset centre;
  final double radius;
  final double _sinLon, _cosLon, _sinLat, _cosLat;

  /// Screen position of a surface point (degrees). Far-side points are
  /// pushed onto the limb so meshes that straddle it stay inside the disc.
  ProjectedPoint project(double latDeg, double lonDeg) {
    final cl = math.cos(latDeg * _rad);
    final wx = cl * math.sin(lonDeg * _rad);
    final wy = math.sin(latDeg * _rad);
    final wz = cl * math.cos(lonDeg * _rad);
    var x = wx * _cosLon - wz * _sinLon;
    final z1 = wx * _sinLon + wz * _cosLon;
    var y = wy * _cosLat - z1 * _sinLat;
    final z = wy * _sinLat + z1 * _cosLat;
    final front = z > 0;
    if (!front) {
      final len = math.sqrt(x * x + y * y);
      if (len > 1e-12) {
        x /= len;
        y /= len;
      }
    }
    return ProjectedPoint(
      centre.dx + x * radius,
      centre.dy - y * radius,
      front: front,
    );
  }

  /// Surface point (lat, lon in degrees) under a screen position, or null
  /// off the disc.
  (double, double)? unproject(Offset p) {
    if (radius <= 0) return null;
    final u = (p.dx - centre.dx) / radius;
    final v = (centre.dy - p.dy) / radius;
    final d = u * u + v * v;
    if (d > 1) return null;
    final z = math.sqrt(math.max(0, 1 - d));
    final wy = v * _cosLat + z * _sinLat;
    final z1 = -v * _sinLat + z * _cosLat;
    final wx = u * _cosLon + z1 * _sinLon;
    final wz = -u * _sinLon + z1 * _cosLon;
    return (math.asin(wy.clamp(-1.0, 1.0)) / _rad, math.atan2(wx, wz) / _rad);
  }
}

/// Lat/long to texture coordinates on an equirectangular map.
///
/// u runs west to east from (centre - 180) to (centre + 180) degrees,
/// v runs from the north pole (0) to the south pole (1).
(double, double) equirectUv(
  double latDeg,
  double lonDeg, {
  double centreLongitudeDeg = 0,
}) {
  final u = ((lonDeg - centreLongitudeDeg + 180) / 360) % 1.0;
  final v = ((90 - latDeg) / 180).clamp(0.0, 1.0);
  return (u, v);
}

/// Pixel position of a surface point on a whole map [level].
Offset texelOnLevel(
  MoonManifest manifest,
  MoonLevel level,
  double latDeg,
  double lonDeg,
) {
  final (u, v) = equirectUv(
    latDeg,
    lonDeg,
    centreLongitudeDeg: manifest.centreLongitudeDeg,
  );
  return Offset(u * level.width, v * level.height);
}

/// The tile of [level] holding a surface point, with the pixel inside it.
({int column, int row, String file, Offset local}) tileTexel(
  MoonManifest manifest,
  MoonLevel level,
  double latDeg,
  double lonDeg,
) {
  final t = texelOnLevel(manifest, level, latDeg, lonDeg);
  final col = (t.dx ~/ level.tileWidth).clamp(0, level.columns - 1);
  final row = (t.dy ~/ level.tileHeight).clamp(0, level.rows - 1);
  return (
    column: col,
    row: row,
    file: level.fileAt(col, row),
    local: Offset(t.dx - col * level.tileWidth, t.dy - row * level.tileHeight),
  );
}

/// A lon/lat rectangle of the map covered by one image.
class MapRegion {
  const MapRegion({
    required this.westDeg,
    required this.northDeg,
    required this.spanLonDeg,
    required this.spanLatDeg,
  });

  /// The whole map (the default image).
  factory MapRegion.whole(MoonManifest m) => MapRegion(
    westDeg: m.centreLongitudeDeg - 180,
    northDeg: 90,
    spanLonDeg: 360,
    spanLatDeg: 180,
  );

  /// One tile of a level.
  factory MapRegion.tile(MoonManifest m, MoonLevel level, int col, int row) {
    final dLon = 360 / level.columns, dLat = 180 / level.rows;
    return MapRegion(
      westDeg: m.centreLongitudeDeg - 180 + col * dLon,
      northDeg: 90 - row * dLat,
      spanLonDeg: dLon,
      spanLatDeg: dLat,
    );
  }

  final double westDeg, northDeg, spanLonDeg, spanLatDeg;
}
