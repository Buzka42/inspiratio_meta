import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/health/analysis_input.dart';
import 'package:illunis_client/health/checkin.dart';
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/health/health_port.dart';
import 'package:illunis_client/health/imported_signals.dart';
import 'package:illunis_client/memory/local_memory_backend.dart';
import 'package:illunis_client/memory/memory_note.dart';
import 'package:illunis_client/memory/owner_import_bundle.dart';
import 'package:illunis_client/memory/owner_import_loader.dart';

import '../../tool/import_owner_data.dart' as tool;

// The one-time owner import on start, with a bundle built from the synthetic
// fixture by the real tool.

final now = DateTime.now();

Future<Directory> pushBundle() async {
  final dir = await Directory.systemTemp.createTemp('illunis_owner_import');
  addTearDown(() => dir.delete(recursive: true));
  final r = tool.parseOwnerExport(jsonDecode(File('test/tool/fixtures/old_illunis_synthetic.json').readAsStringSync()), now: now);
  File('${dir.path}/$ownerImportDir/$ownerImportFile')
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(r.toJson()));
  return dir;
}

/// Lets writes through, or drops them as [GuardedStore] does on failure.
class _DroppingStore extends InMemoryStateStore {
  bool drop = false;
  @override
  Future<void> setString(String key, String value) async {
    if (!drop) await super.setString(key, value);
  }
}

void main() {
  test('imports notes and signals once, then deletes the bundle', () async {
    final dir = await pushBundle();
    final store = InMemoryStateStore();
    final lines = <String>[];
    final memory = LocalMemoryBackend(store);
    await memory.write(const MemoryNote(text: 'User said: an older synthetic note', label: MemoryLabel.note, confidence: 0.8));
    final signals = ImportedSignalsStore(store);

    final r = await loadOwnerImport(supportDir: dir.path, memory: memory, signals: signals, log: lines.add);
    expect(r!.notesAdded, 5);
    expect(r.signalDays, 2);
    expect(File('${dir.path}/$ownerImportDir/$ownerImportFile').existsSync(), isFalse);
    expect((await memory.summary()).noteCount, 6);
    expect(lines, ['import: done notes_added=5 notes_in_bundle=5 signal_days=2']);

    // A fresh backend reads the imported notes back, original times and source kept.
    final again = LocalMemoryBackend(store);
    final recalled = await again.recall('zebra omelette');
    expect(recalled.single.source, 'import:old_illunis');
    expect(recalled.single.kind, 'note');
    final raw = jsonDecode((await store.getString(StoreKeys.longTermMemory))!) as Map;
    final first = (raw['notes'] as List).first as Map;
    expect(first['import_id'], 'old_illunis:j:synthJ0000000000001'); // Sorted by original time.
    expect(DateTime.parse(first['created_at'] as String).isAtSameMomentAs(DateTime(2026, 1, 2, 8, 15, 30, 123, 456)), isTrue);

    // Pushed again: nothing added.
    final dir2 = await pushBundle();
    final r2 = await loadOwnerImport(supportDir: dir2.path, memory: again, signals: signals, log: lines.add);
    expect(r2!.notesAdded, 0);
    expect(r2.signalDays, 0);
    expect((await again.summary()).noteCount, 6);
  });

  test('no bundle, an empty support dir or a bad bundle never throw', () async {
    final store = InMemoryStateStore();
    final lines = <String>[];
    final memory = LocalMemoryBackend(store), signals = ImportedSignalsStore(store);
    expect(await loadOwnerImport(supportDir: '', memory: memory, signals: signals, log: lines.add), isNull);
    final dir = await Directory.systemTemp.createTemp('illunis_owner_import');
    addTearDown(() => dir.delete(recursive: true));
    expect(await loadOwnerImport(supportDir: dir.path, memory: memory, signals: signals, log: lines.add), isNull);
    final f = File('${dir.path}/$ownerImportDir/$ownerImportFile')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"v": 1, "notes": []}');
    expect(await loadOwnerImport(supportDir: dir.path, memory: memory, signals: signals, log: lines.add), isNull);
    expect(lines, ['import: unreadable bundle']);
    expect(f.existsSync(), isTrue);
  });

  test('a dropped write keeps the bundle for the next start', () async {
    final dir = await pushBundle();
    final store = _DroppingStore()..drop = true;
    final lines = <String>[];
    await loadOwnerImport(
        supportDir: dir.path, memory: LocalMemoryBackend(store), signals: ImportedSignalsStore(store), log: lines.add);
    expect(lines.first, 'import: incomplete, bundle kept');
    expect(File('${dir.path}/$ownerImportDir/$ownerImportFile').existsSync(), isTrue);
    store.drop = false;
    final r = await loadOwnerImport(
        supportDir: dir.path, memory: LocalMemoryBackend(store), signals: ImportedSignalsStore(store), log: lines.add);
    expect(r!.notesAdded, 5);
    expect(File('${dir.path}/$ownerImportDir/$ownerImportFile').existsSync(), isFalse);
  });

  test('importNotes skips known ids, known texts and expired notes', () async {
    final store = InMemoryStateStore();
    final memory = LocalMemoryBackend(store, clock: () => DateTime.utc(2026, 10, 25));
    await memory.write(const MemoryNote(text: 'Same text', label: MemoryLabel.note, confidence: 0.8));
    ImportedNote n(String id, String text, {DateTime? expires}) => ImportedNote(
        id: id,
        createdAt: DateTime.utc(2026, 1, 1),
        note: MemoryNote(text: text, label: MemoryLabel.observation, confidence: 0.5, expiresAt: expires, source: 'import:x'));
    expect(
        await memory.importNotes([
          n('a', 'synthetic one'),
          n('a', 'synthetic one again'),
          n('b', 'same TEXT'),
          n('c', 'gone', expires: DateTime.utc(2026, 2, 1)),
        ]),
        1);
    expect(await memory.importNotes([n('a', 'synthetic one')]), 0);
  });

  test('imported days fill the analysis where Health Connect has none', () async {
    final store = InMemoryStateStore();
    final imported = ImportedSignalsStore(store);
    final today = DateTime(2026, 10, 25);
    await imported.merge([
      const DailySignals(day: '2026-10-20', steps: 1000),
      const DailySignals(day: '2026-10-21', steps: 2000),
      const DailySignals(day: '2026-01-01', steps: 3000), // Outside the window.
    ]);
    expect(await imported.merge([const DailySignals(day: '2026-10-20', steps: 1000)]), 0);
    final health = FakeHealthPort(granted: true, days: [const DailySignals(day: '2026-10-21', steps: 9999)]);
    final input = await collectAnalysisInput(
        checkIns: CheckInStore(store), health: health, today: today, imported: imported);
    expect([for (final s in input.signals) '${s.day}:${s.steps}'], ['2026-10-20:1000', '2026-10-21:9999']);
  });
}
