/// One-time owner import on start. tool/push_owner_import.sh copies the
/// bundle from tool/import_owner_data.dart to
/// `<support dir>/import/owner_import.json`; [loadOwnerImport] adds its notes
/// to the phone's long-term memory and its days to [ImportedSignalsStore],
/// then deletes the file once a fresh read shows everything stored. Notes
/// carry stable ids, so a bundle pushed twice adds nothing. Logs counts and
/// codes only, never content.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../health/imported_signals.dart';
import 'local_memory_backend.dart';
import 'owner_import_bundle.dart';

class OwnerImportResult {
  const OwnerImportResult({required this.notesAdded, required this.notesInBundle, required this.signalDays});
  final int notesAdded;
  final int notesInBundle;
  final int signalDays;
}

/// Null when there is no bundle or it could not be imported. Never throws.
Future<OwnerImportResult?> loadOwnerImport({
  required String supportDir,
  required LocalMemoryBackend memory,
  required ImportedSignalsStore signals,
  void Function(String line)? log,
}) async {
  final say = log ?? debugPrint;
  if (supportDir.isEmpty) return null;
  final file = File('$supportDir/$ownerImportDir/$ownerImportFile');
  try {
    if (!await file.exists()) return null;
    final bundle = OwnerImportBundle.fromJson(jsonDecode(await file.readAsString()));
    final added = await memory.importNotes(bundle.notes);
    final changed = await signals.merge(bundle.signals);
    // The store swallows write failures, so check before the file goes.
    final keys = await LocalMemoryBackend.storedKeys(memory.store);
    final now = DateTime.now();
    final notesStored = bundle.notes.every((n) =>
        keys.contains(n.id) ||
        keys.contains(n.note.text.trim().toLowerCase()) ||
        !(n.note.expiresAt?.isAfter(now) ?? true));
    final days = {for (final s in await signals.all()) s.day: s};
    final daysStored = bundle.signals.every((s) => days[s.day] == s);
    if (notesStored && daysStored) {
      await file.delete();
    } else {
      say('import: incomplete, bundle kept');
    }
    say('import: done notes_added=$added notes_in_bundle=${bundle.notes.length} signal_days=$changed');
    return OwnerImportResult(notesAdded: added, notesInBundle: bundle.notes.length, signalDays: changed);
  } on FormatException {
    say('import: unreadable bundle');
  } catch (e) {
    say('import: failed error=${e.runtimeType}');
  }
  return null;
}
