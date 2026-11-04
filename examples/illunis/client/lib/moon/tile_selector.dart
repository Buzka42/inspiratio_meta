import 'dart:math' as math;

import 'moon_manifest.dart';
import 'moon_view.dart';

/// The level and tile files needed for one frame.
class MoonSelection {
  const MoonSelection(this.level, this.files);
  final MoonLevel level;

  /// Visible tile files, in row-major order.
  final List<String> files;
}

/// Picks the map level and the visible tiles for a [MoonView].
///
/// Orthographic disc: at zoom z the disc radius is R = fitRadius * z
/// pixels, so one pixel at the disc centre spans 1/R radians and a map
/// gives one texel per pixel when width >= 2 * pi * R. [slack] allows up
/// to that much magnification before moving to a finer level ("about"
/// one texel per pixel), and sets the maximum zoom on the finest level.
class TileSelector {
  const TileSelector(this.manifest, {this.slack = 1.25});

  final MoonManifest manifest;
  final double slack;

  /// Map width giving one texel per screen pixel at the disc centre.
  static double requiredWidth(MoonView view, MoonScreen screen) =>
      2 * math.pi * screen.fitRadius * view.zoom;

  /// Largest zoom at which the finest level still meets the target.
  double maxZoom(MoonScreen screen) => math.max(
    1.0,
    manifest.finest.width * slack / (2 * math.pi * screen.fitRadius),
  );

  /// Coarsest level meeting the target; the finest if none does.
  MoonLevel levelFor(MoonView view, MoonScreen screen) {
    final need = requiredWidth(view, screen);
    for (final level in manifest.allLevels) {
      if (level.width * slack >= need) return level;
    }
    return manifest.finest;
  }

  MoonSelection select(MoonView view, MoonScreen screen) {
    final level = levelFor(view, screen);
    return MoonSelection(level, visibleTiles(level, view, screen));
  }

  /// Files of [level] that show at least one visible point. Combines a
  /// screen-space sweep (catches tiles larger than the step) with a sweep
  /// over each tile's own lon/lat grid (catches slivers near the limb).
  List<String> visibleTiles(
    MoonLevel level,
    MoonView view,
    MoonScreen screen, {
    double stepPx = 16,
    int tileSamples = 8,
  }) {
    final p = _Projection(view, screen);
    assert(stepPx > 0 && tileSamples > 0, 'sampling must be positive');
    if (p.radius <= 0 || screen.width < 1 || screen.height < 1) {
      return const [];
    }
    final hit = <int>{};
    void mark(double latDeg, double lonDeg) =>
        hit.add(_index(level, latDeg, lonDeg));

    // Pixel centres, always including the last row and column.
    final lastX = screen.width - 0.5, lastY = screen.height - 0.5;
    for (var y = 0.5; ; y = math.min(y + stepPx, lastY)) {
      for (var x = 0.5; ; x = math.min(x + stepPx, lastX)) {
        final ll = p.unproject(x, y);
        if (ll != null) mark(ll.$1, ll.$2);
        if (x >= lastX) break;
      }
      if (y >= lastY) break;
    }

    if (level.columns * level.rows > 1) {
      final tileLon = 360 / level.columns;
      final tileLat = 180 / level.rows;
      final lonStart = manifest.centreLongitudeDeg - 180;
      for (var r = 0; r < level.rows; r++) {
        for (var c = 0; c < level.columns; c++) {
          final i = r * level.columns + c;
          if (hit.contains(i)) continue;
          if (_tileSeen(
            p,
            lonStart + c * tileLon,
            90 - r * tileLat,
            tileLon,
            tileLat,
            tileSamples,
          )) {
            hit.add(i);
          }
        }
      }
    }
    final sorted = hit.toList()..sort();
    return [for (final i in sorted) level.files[i]];
  }

  bool _tileSeen(
    _Projection p,
    double lon0,
    double latTop,
    double dLon,
    double dLat,
    int n,
  ) {
    for (var j = 0; j <= n; j++) {
      for (var i = 0; i <= n; i++) {
        if (p.onScreen(latTop - dLat * j / n, lon0 + dLon * i / n)) return true;
      }
    }
    return false;
  }

  int _index(MoonLevel level, double latDeg, double lonDeg) {
    final u = ((lonDeg - manifest.centreLongitudeDeg + 180) / 360) % 1.0;
    final v = (90 - latDeg) / 180;
    final col = (u * level.columns).floor().clamp(0, level.columns - 1);
    final row = (v * level.rows).floor().clamp(0, level.rows - 1);
    return row * level.columns + col;
  }
}

/// Orthographic projection of the moon sphere for one view.
///
/// World: lon 0, lat 0 faces the viewer; view axes x right, y up, z toward
/// the viewer. World to view is a rotation about y by -lon0, then about x
/// by lat0.
class _Projection {
  _Projection(MoonView view, MoonScreen screen)
    : radius = screen.fitRadius * view.zoom,
      width = screen.width,
      height = screen.height,
      _sinLon = math.sin(view.longitudeDeg * _rad),
      _cosLon = math.cos(view.longitudeDeg * _rad),
      _sinLat = math.sin(view.latitudeDeg * _rad),
      _cosLat = math.cos(view.latitudeDeg * _rad);

  static const _rad = math.pi / 180;
  final double radius, width, height;
  final double _sinLon, _cosLon, _sinLat, _cosLat;

  /// Whether a surface point faces the viewer and lands on screen.
  bool onScreen(double latDeg, double lonDeg) {
    final cl = math.cos(latDeg * _rad);
    final wx = cl * math.sin(lonDeg * _rad);
    final wy = math.sin(latDeg * _rad);
    final wz = cl * math.cos(lonDeg * _rad);
    final x1 = wx * _cosLon - wz * _sinLon;
    final z1 = wx * _sinLon + wz * _cosLon;
    final y = wy * _cosLat - z1 * _sinLat;
    final z = wy * _sinLat + z1 * _cosLat;
    // Strict tests: a tile that only touches the limb or the screen edge
    // shows no pixels.
    if (z <= 1e-9) return false;
    final sx = width / 2 + x1 * radius;
    final sy = height / 2 - y * radius;
    return sx > 0 && sx < width && sy > 0 && sy < height;
  }

  /// Surface point (lat, lon in degrees) under a screen pixel, or null off
  /// the disc.
  (double, double)? unproject(double px, double py) {
    final u = (px - width / 2) / radius;
    final v = (height / 2 - py) / radius;
    final d = u * u + v * v;
    if (d >= 1) return null;
    final z = math.sqrt(1 - d);
    // Inverse: rotate about x by -lat0, then about y by +lon0.
    final wy = v * _cosLat + z * _sinLat;
    final z1 = -v * _sinLat + z * _cosLat;
    final wx = u * _cosLon + z1 * _sinLon;
    final wz = -u * _sinLon + z1 * _cosLon;
    return (math.asin(wy.clamp(-1.0, 1.0)) / _rad, math.atan2(wx, wz) / _rad);
  }
}
