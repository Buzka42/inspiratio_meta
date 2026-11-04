import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Reads width and height from a JPEG's start-of-frame marker.
(int, int) jpegSize(Uint8List b) {
  var i = 2; // skip SOI
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) throw FormatException('bad marker at $i');
    final m = b[i + 1];
    final len = (b[i + 2] << 8) | b[i + 3];
    final isSof = m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
    if (isSof) {
      return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
    }
    i += 2 + len;
  }
  throw const FormatException('no SOF marker');
}

void main() {
  const root = 'assets/moon';
  final manifest =
      jsonDecode(File('$root/manifest.json').readAsStringSync()) as Map;

  test('manifest carries the NASA SVS credit', () {
    expect(manifest['credit'], contains('svs.gsfc.nasa.gov/4720'));
  });

  test('default map exists at its listed size', () {
    final d = manifest['default'] as Map;
    final f = File('$root/${d['file']}');
    expect(f.existsSync(), isTrue);
    expect(jpegSize(f.readAsBytesSync()), (d['width'], d['height']));
  });

  test('every listed tile exists at the tile size', () {
    final size = manifest['tile_size'] as int;
    for (final level in manifest['levels'] as List) {
      final files = (level['files'] as List).cast<String>();
      expect(files.length, level['columns'] * level['rows']);
      expect(level['columns'] * size, level['width']);
      expect(level['rows'] * size, level['height']);
      for (final name in files) {
        final f = File('$root/$name');
        expect(f.existsSync(), isTrue, reason: name);
        expect(jpegSize(f.readAsBytesSync()), (size, size), reason: name);
      }
    }
  });
}
