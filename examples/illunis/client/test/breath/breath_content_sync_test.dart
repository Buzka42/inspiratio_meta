// The asset copy (tool/sync_breath_content.sh) equals content/ byte for
// byte: the same technique files, no extra or stale ones, and the schema.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, List<int>> jsonFiles(String dir, {String? except}) => {
      for (final f in Directory(dir).listSync().whereType<File>())
        if (f.path.endsWith('.json') && f.uri.pathSegments.last != except)
          f.uri.pathSegments.last: f.readAsBytesSync(),
    };

void main() {
  const fix = 'run tool/sync_breath_content.sh';

  test('every technique in content/breathwork is copied unchanged, with no extras', () {
    final content = jsonFiles('../content/breathwork');
    final assets = jsonFiles('assets/breath', except: 'technique.schema.json');
    expect(content, isNotEmpty);
    expect(assets.keys.toSet(), content.keys.toSet(), reason: fix);
    for (final name in content.keys) {
      expect(assets[name], content[name], reason: '$name differs; $fix');
    }
  });

  test('the schema is copied unchanged', () {
    expect(File('assets/breath/technique.schema.json').readAsBytesSync(),
        File('../content/schemas/technique.schema.json').readAsBytesSync(),
        reason: fix);
  });
}
