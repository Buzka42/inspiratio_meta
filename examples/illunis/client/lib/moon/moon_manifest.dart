import 'dart:convert';

/// Why a moon manifest was rejected.
enum ManifestError {
  notJson,
  notObject,
  badProjection,
  badCentreLongitude,
  badDefault,
  badTileSize,
  noLevels,
  badLevel,
  badDimensions,
  tileCountMismatch,
  badFileName,
  duplicateFile,
}

/// One resolution of the equirectangular colour map, cut into a grid of
/// tiles. The default map is a level with a single tile.
class MoonLevel {
  const MoonLevel({
    required this.level,
    required this.width,
    required this.height,
    required this.columns,
    required this.rows,
    required this.files,
  });

  /// Manifest level number, or null for the untiled default map.
  final int? level;
  final int width;
  final int height;
  final int columns;
  final int rows;

  /// Tile files in row-major order (row 0 is the north edge).
  final List<String> files;

  bool get isDefault => level == null;
  int get tileWidth => width ~/ columns;
  int get tileHeight => height ~/ rows;

  String fileAt(int column, int row) => files[row * columns + column];
}

/// Parsed client/assets/moon/manifest.json (written by
/// moon_assets/build_moon_assets.py).
class MoonManifest {
  const MoonManifest({
    required this.defaultMap,
    required this.tileSize,
    required this.levels,
    this.centreLongitudeDeg = 0,
    this.credit = '',
  });

  /// The 4096x2048 default view.
  final MoonLevel defaultMap;
  final int tileSize;

  /// Tiled levels, ascending by width.
  final List<MoonLevel> levels;

  /// Longitude at the horizontal centre of every map.
  final double centreLongitudeDeg;
  final String credit;

  /// Default map first, then tiled levels, ascending by width.
  List<MoonLevel> get allLevels => [defaultMap, ...levels];

  MoonLevel get finest => levels.isEmpty ? defaultMap : levels.last;
}

sealed class ManifestResult {
  const ManifestResult();
}

class ManifestOk extends ManifestResult {
  const ManifestOk(this.manifest);
  final MoonManifest manifest;
}

class ManifestRejected extends ManifestResult {
  const ManifestRejected(this.code, this.detail);
  final ManifestError code;
  final String detail;

  @override
  String toString() => 'ManifestRejected(${code.name}: $detail)';
}

class _Reject implements Exception {
  _Reject(this.code, this.detail);
  final ManifestError code;
  final String detail;
}

const _maxPixels = 65536;
final _safeSegment = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]*$');

/// Parses manifest text. Never throws: any problem is a [ManifestRejected].
ManifestResult parseMoonManifest(String text) {
  Object? root;
  try {
    root = jsonDecode(text);
  } on FormatException catch (e) {
    return ManifestRejected(ManifestError.notJson, e.message);
  }
  try {
    return ManifestOk(_manifest(root));
  } on _Reject catch (e) {
    return ManifestRejected(e.code, e.detail);
  }
}

MoonManifest _manifest(Object? root) {
  if (root is! Map<String, Object?>) {
    throw _Reject(ManifestError.notObject, 'top level is not an object');
  }
  final projection = root['projection'];
  if (projection != null && projection != 'equirectangular') {
    throw _Reject(ManifestError.badProjection, '$projection');
  }
  final centre = root['centre_longitude_deg'] ?? 0;
  if (centre is! num || !centre.isFinite || centre.abs() > 180) {
    throw _Reject(ManifestError.badCentreLongitude, '$centre');
  }
  final seen = <String>{};

  final def = root['default'];
  if (def is! Map<String, Object?>) {
    throw _Reject(ManifestError.badDefault, 'missing default map');
  }
  final defW = _dimension(def['width'], ManifestError.badDefault);
  final defH = _dimension(def['height'], ManifestError.badDefault);
  _equirect(defW, defH, 'default');
  final defaultMap = MoonLevel(
    level: null,
    width: defW,
    height: defH,
    columns: 1,
    rows: 1,
    files: [_fileName(def['file'], seen)],
  );

  final tileSize = root['tile_size'];
  if (tileSize is! int || tileSize <= 0 || tileSize > _maxPixels) {
    throw _Reject(ManifestError.badTileSize, '$tileSize');
  }

  final rawLevels = root['levels'];
  if (rawLevels is! List<Object?> || rawLevels.isEmpty) {
    throw _Reject(ManifestError.noLevels, 'levels missing or empty');
  }
  final levels = <MoonLevel>[];
  final numbers = <int>{};
  for (final raw in rawLevels) {
    if (raw is! Map<String, Object?>) {
      throw _Reject(ManifestError.badLevel, 'level is not an object');
    }
    final number = raw['level'];
    if (number is! int || number < 0 || !numbers.add(number)) {
      throw _Reject(ManifestError.badLevel, 'bad or repeated level $number');
    }
    final w = _dimension(raw['width'], ManifestError.badDimensions);
    final h = _dimension(raw['height'], ManifestError.badDimensions);
    _equirect(w, h, 'level $number');
    final cols = raw['columns'];
    final rows = raw['rows'];
    if (cols is! int ||
        rows is! int ||
        cols * tileSize != w ||
        rows * tileSize != h) {
      throw _Reject(
        ManifestError.badDimensions,
        'level $number grid $cols x $rows does not cover ${w}x$h',
      );
    }
    final files = raw['files'];
    if (files is! List<Object?> || files.length != cols * rows) {
      throw _Reject(
        ManifestError.tileCountMismatch,
        'level $number needs ${cols * rows} files',
      );
    }
    levels.add(
      MoonLevel(
        level: number,
        width: w,
        height: h,
        columns: cols,
        rows: rows,
        files: [for (final f in files) _fileName(f, seen)],
      ),
    );
  }
  levels.sort((a, b) => a.width.compareTo(b.width));
  for (var i = 0; i < levels.length; i++) {
    final below = i == 0 ? defaultMap.width : levels[i - 1].width;
    if (levels[i].width <= below) {
      throw _Reject(
        ManifestError.badLevel,
        'level ${levels[i].level} is not finer than the one below',
      );
    }
  }
  final credit = root['credit'];
  return MoonManifest(
    defaultMap: defaultMap,
    tileSize: tileSize,
    levels: List.unmodifiable(levels),
    centreLongitudeDeg: centre.toDouble(),
    credit: credit is String ? credit : '',
  );
}

int _dimension(Object? value, ManifestError code) {
  if (value is! int || value <= 0 || value > _maxPixels) {
    throw _Reject(code, 'bad dimension $value');
  }
  return value;
}

void _equirect(int w, int h, String what) {
  if (w != 2 * h) {
    throw _Reject(ManifestError.badDimensions, '$what is ${w}x$h, not 2:1');
  }
}

/// Accepts relative asset paths only: no absolute paths, no `..`.
String _fileName(Object? value, Set<String> seen) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 256 ||
      !value.split('/').every(_safeSegment.hasMatch)) {
    throw _Reject(ManifestError.badFileName, 'unsafe file name');
  }
  if (!seen.add(value)) {
    throw _Reject(ManifestError.duplicateFile, value);
  }
  return value;
}
