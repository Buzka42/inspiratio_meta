import 'dart:convert';

/// Manifest in the shape moon_assets/build_moon_assets.py writes.
Map<String, Object?> sampleManifestJson() {
  const tile = 512, w = 8192, h = 4096;
  const cols = w ~/ tile, rows = h ~/ tile;
  return {
    'projection': 'equirectangular',
    'centre_longitude_deg': 0,
    'credit': 'NASA SVS CGI Moon Kit',
    'jpeg_quality': 90,
    'default': {'file': 'default.jpg', 'width': 4096, 'height': 2048},
    'tile_size': tile,
    'levels': [
      {
        'level': 0,
        'width': w,
        'height': h,
        'columns': cols,
        'rows': rows,
        'pattern': 'tiles/L{level}_{x}_{y}.jpg',
        'files': <Object?>[
          for (var y = 0; y < rows; y++)
            for (var x = 0; x < cols; x++) 'tiles/L0_${x}_$y.jpg',
        ],
      },
    ],
  };
}

String sampleManifestText() => jsonEncode(sampleManifestJson());
