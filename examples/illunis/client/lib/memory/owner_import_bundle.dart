/// The owner-import bundle written by tool/import_owner_data.dart and read
/// once by the app (owner_import_loader.dart): `{v, source, notes: [{id,
/// text, kind, source, confidence, created_at, expires_at}], signals: [{day,
/// sleep_minutes, steps, resting_hr}]}`. Pure Dart, so `dart run` can use it.
library;

import '../health/daily_signals.dart';
import 'memory_note.dart';

const ownerImportVersion = 2;

/// Under the app support dir (`<app data>/files` on Android).
const ownerImportDir = 'import';
const ownerImportFile = 'owner_import.json';

/// One note from an export. [id] is stable for the same source entry, so a
/// second import adds nothing.
class ImportedNote {
  const ImportedNote({required this.id, required this.note, required this.createdAt});
  final String id;
  final MemoryNote note;
  final DateTime createdAt;

  Map<String, dynamic> toJson() =>
      {'id': id, ...note.toJson(), 'created_at': createdAt.toUtc().toIso8601String()};

  static final _idRe = RegExp(r'^[A-Za-z0-9:_-]{1,128}$');

  /// Null for a malformed entry.
  static ImportedNote? fromJson(Object? j) {
    final n = MemoryNote.fromJson(j);
    if (n == null || j is! Map) return null;
    final id = j['id'], c = j['created_at'];
    final created = c is String ? DateTime.tryParse(c) : null;
    if (id is! String || !_idRe.hasMatch(id) || created == null) return null;
    return ImportedNote(id: id, note: n, createdAt: created);
  }
}

class OwnerImportBundle {
  const OwnerImportBundle({required this.notes, required this.signals});
  final List<ImportedNote> notes;
  final List<DailySignals> signals;

  /// Throws [FormatException] for a wrong version or shape; bad entries are
  /// dropped.
  static OwnerImportBundle fromJson(Object? j) {
    if (j is! Map || j['v'] != ownerImportVersion) throw const FormatException('owner import version');
    final notes = j['notes'], signals = j['signals'];
    if (notes is! List || signals is! List) throw const FormatException('owner import shape');
    return OwnerImportBundle(
      notes: [for (final n in notes) ?ImportedNote.fromJson(n)],
      signals: [
        for (final s in signals)
          if (DailySignals.fromJson(s) case final d? when !d.isEmpty) d,
      ],
    );
  }
}
