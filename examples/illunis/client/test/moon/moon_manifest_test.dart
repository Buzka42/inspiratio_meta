import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/moon_manifest.dart';

import 'moon_test_fixtures.dart';

ManifestError? codeOf(ManifestResult r) =>
    r is ManifestRejected ? r.code : null;

ManifestResult parseEdited(void Function(Map<String, Object?> m) edit) {
  final m = sampleManifestJson();
  edit(m);
  return parseMoonManifest(jsonEncode(m));
}

Map<String, Object?> level0(Map<String, Object?> m) =>
    (m['levels'] as List).first as Map<String, Object?>;

void main() {
  test('parses the builder manifest', () {
    final r = parseMoonManifest(sampleManifestText());
    expect(r, isA<ManifestOk>());
    final m = (r as ManifestOk).manifest;
    expect(m.defaultMap.width, 4096);
    expect(m.defaultMap.files, ['default.jpg']);
    expect(m.tileSize, 512);
    expect(m.levels.single.columns, 16);
    expect(m.levels.single.rows, 8);
    expect(m.levels.single.fileAt(3, 2), 'tiles/L0_3_2.jpg');
    expect(m.allLevels.map((l) => l.width), [4096, 8192]);
  });

  group('rejects a bad manifest with a code', () {
    test('not JSON', () {
      expect(codeOf(parseMoonManifest('{levels: ')), ManifestError.notJson);
      expect(codeOf(parseMoonManifest('')), ManifestError.notJson);
    });
    test('not an object', () {
      expect(codeOf(parseMoonManifest('[1, 2]')), ManifestError.notObject);
    });
    test('missing levels', () {
      expect(
        codeOf(parseEdited((m) => m.remove('levels'))),
        ManifestError.noLevels,
      );
      expect(
        codeOf(parseEdited((m) => m['levels'] = [])),
        ManifestError.noLevels,
      );
    });
    test('bad tile size', () {
      expect(
        codeOf(parseEdited((m) => m['tile_size'] = 'big')),
        ManifestError.badTileSize,
      );
      expect(
        codeOf(parseEdited((m) => m['tile_size'] = 0)),
        ManifestError.badTileSize,
      );
    });
    test('grid does not cover the dimensions', () {
      expect(
        codeOf(parseEdited((m) => level0(m)['columns'] = 15)),
        ManifestError.badDimensions,
      );
      expect(
        codeOf(parseEdited((m) => level0(m)['height'] = 8192)),
        ManifestError.badDimensions,
      );
    });
    test('wrong tile count', () {
      expect(
        codeOf(parseEdited((m) => (level0(m)['files'] as List).removeLast())),
        ManifestError.tileCountMismatch,
      );
    });
    test('unsafe or duplicate file names', () {
      expect(
        codeOf(
          parseEdited((m) => (level0(m)['files'] as List)[0] = '../secret.jpg'),
        ),
        ManifestError.badFileName,
      );
      expect(
        codeOf(
          parseEdited((m) => (level0(m)['files'] as List)[0] = '/etc/passwd'),
        ),
        ManifestError.badFileName,
      );
      expect(
        codeOf(parseEdited((m) => (level0(m)['files'] as List)[0] = 42)),
        ManifestError.badFileName,
      );
      expect(
        codeOf(
          parseEdited(
            (m) => (level0(m)['files'] as List)[1] = 'tiles/L0_0_0.jpg',
          ),
        ),
        ManifestError.duplicateFile,
      );
    });
    test('missing default map', () {
      expect(
        codeOf(parseEdited((m) => m.remove('default'))),
        ManifestError.badDefault,
      );
    });
    test('other projection', () {
      expect(
        codeOf(parseEdited((m) => m['projection'] = 'mercator')),
        ManifestError.badProjection,
      );
    });
    test('level no finer than the default', () {
      expect(
        codeOf(
          parseEdited((m) {
            final l = level0(m);
            l['width'] = 4096;
            l['height'] = 2048;
            l['columns'] = 8;
            l['rows'] = 4;
            l['files'] = [for (var i = 0; i < 32; i++) 'tiles/x$i.jpg'];
          }),
        ),
        ManifestError.badLevel,
      );
    });
  });
}
