import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/memory/owner_import_bundle.dart';

import '../../tool/import_owner_data.dart';

// The old-Illunis importer, on a synthetic export only
// (test/tool/fixtures/old_illunis_synthetic.json, shared with the Hermes
// tool's tests).

class _Sink implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

const fixturePath = 'test/tool/fixtures/old_illunis_synthetic.json';
final now = DateTime.utc(2026, 10, 25);

Object? fixture() => jsonDecode(File(fixturePath).readAsStringSync());

void main() {
  test('journal, nutrition and summaries map to notes and signals', () {
    final r = parseOwnerExport(fixture(), now: now);
    expect(r.counts,
        'journal_notes=3 excluded_from_ai=1 day_notes=2 signals=2 nutrition_used=2 nutrition_excluded=1 skipped=1');
    final notes = {for (final n in r.bundle.notes) n.id: n};
    expect(notes.keys, [
      'old_illunis:j:synthJ0000000000001',
      'old_illunis:j:synthJ0000000000002',
      'old_illunis:d:2026-01-02',
      'old_illunis:j:synthJ0000000000005',
      'old_illunis:d:2026-01-04',
    ]); // Oldest first.

    final self = notes['old_illunis:j:synthJ0000000000001']!;
    expect(self.note.label.kind, 'note');
    expect(self.note.text, 'User wrote on 2026-01-02: I ate a synthetic zebra omelette');
    expect(self.note.expiresAt, isNull);
    expect(self.note.source, 'import:old_illunis');
    expect(self.createdAt, DateTime(2026, 1, 2, 8, 15, 30, 123, 456)); // Original local time.

    final other = notes['old_illunis:j:synthJ0000000000002']!;
    expect(other.note.label.kind, 'hypothesis');
    expect(other.note.text, 'Old journal, 2026-01-02: two quokka sandwiches');
    expect(other.note.expiresAt, now.add(hypothesisLifetime));
    expect(notes['old_illunis:j:synthJ0000000000005']!.note.label.kind, 'note');

    // Nutrition wins over the summary's intake; the excluded entry's food is left out.
    expect(notes['old_illunis:d:2026-01-02']!.note.text, 'On 2026-01-02: ~800 kcal in, protein 20 g, sleep 7.5 h, steps 8000');
    expect(notes['old_illunis:d:2026-01-04']!.note.text, 'On 2026-01-04: ~1800 kcal in, protein 90 g, steps 4321');
    expect(notes['old_illunis:d:2026-01-02']!.note.label.kind, 'hypothesis');

    expect([for (final n in r.bundle.notes) n.note.text].join(), isNot(contains('wombat')));
    expect([for (final s in r.bundle.signals) s.toJson()], [
      {'day': '2026-01-02', 'sleep_minutes': 450, 'steps': 8000, 'resting_hr': null},
      {'day': '2026-01-04', 'sleep_minutes': null, 'steps': 4321, 'resting_hr': null},
    ]);
  });

  test('long entries are cut, not split; ids are stable across runs', () {
    final long = 'I ${'walked ' * 200}';
    final a = parseOwnerExport({
      'journal': [
        {'at': '2026-01-01T10:00:00.000', 'excludedFromAi': false, 'id': 'synthLong01', 'text': long},
        {'at': '2026-01-01T10:00:00.000', 'excludedFromAi': false, 'id': 'bad id!', 'text': 'I x'},
      ],
    }, now: now);
    expect(a.bundle.notes, hasLength(1));
    expect(a.skipped, 1);
    final body = a.bundle.notes.single.note.text.substring('User wrote on 2026-01-01: '.length);
    expect(body.length, lessThanOrEqualTo(maxEntryChars + 3));
    expect(body, endsWith('...'));
    final b = parseOwnerExport(fixture(), now: now), c = parseOwnerExport(fixture(), now: now);
    expect([for (final n in b.bundle.notes) n.id], [for (final n in c.bundle.notes) n.id]);
  });

  test('a wrong top level is a FormatException', () {
    expect(() => parseOwnerExport([1, 2], now: now), throwsFormatException);
    expect(() => parseOwnerExport({'notes': []}, now: now), throwsFormatException);
    expect(() => parseOwnerExport({'journal': [], 'nutrition': 'x'}, now: now), throwsFormatException);
  });

  test('refuses any path inside the old repository, allows the rework', () {
    const home = '/home/synthetic';
    expect(isRefusedSource('/home/synthetic/Projects/illunis/app/data.json', home: home), isTrue);
    expect(isRefusedSource('/home/synthetic/Projects/illunis', home: home), isTrue);
    expect(isRefusedSource('/home/synthetic/Projects/illunis/../illunis/x.json', home: home), isTrue);
    expect(isRefusedSource('/home/synthetic/Projects/illunis-rework/x.json', home: home), isFalse);
    expect(isRefusedSource('/home/synthetic/Downloads/export.json', home: home), isFalse);
  });

  test('run reads a BOM export, writes the bundle the app loads, prints counts only', () async {
    final dir = await Directory.systemTemp.createTemp('illunis_import_test');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/export.txt')..writeAsStringSync('﻿${File(fixturePath).readAsStringSync()}');
    final outDir = '${dir.path}/out';
    final out = _Sink();
    expect(await run([src.path, '--out', outDir], out: out, now: now), 0);
    expect(out.lines.single, startsWith('import: wrote owner_import.json journal_notes=3 '));
    for (final secret in ['zebra', 'quokka', 'wombat', 'Synthetic Town', '10.5']) {
      expect(out.lines.join(), isNot(contains(secret)));
    }
    final written = jsonDecode(File('$outDir/$ownerImportFile').readAsStringSync());
    expect((written as Map)['v'], ownerImportVersion);
    expect(written.toString(), isNot(contains('Synthetic Town'))); // Profile is not imported.
    final bundle = OwnerImportBundle.fromJson(written);
    expect(bundle.notes, hasLength(5));
    expect(bundle.signals, hasLength(2));

    expect(await run([src.path], out: out), 64); // No --out.
    expect(await run(['${dir.path}/missing.json', '--out', outDir], out: out), 66);
    File('${dir.path}/bad.json').writeAsStringSync('[1]');
    expect(await run(['${dir.path}/bad.json', '--out', outDir], out: out), 65);
  });
}
