/// Importer for the owner's export from the old Illunis app.
///
/// ```
/// dart run tool/import_owner_data.dart <export.json> --out <dir>
/// tool/push_owner_import.sh <dir> [adb-serial]
/// ```
///
/// Reads the old app's export (JSON, UTF-8 BOM allowed: `profile`, `journal`,
/// `nutrition`, `summaries`, ...) and writes `<dir>/owner_import.json`, the
/// bundle the phone app loads once on start (lib/memory/owner_import_loader.dart):
///  - journal entries become long-term notes (kind `note` for first-person
///    statements, else `hypothesis`), with their original time; entries with
///    `excludedFromAi` are skipped, and so is the nutrition logged from them;
///  - each day with a summary or nutrition gets one short `hypothesis` note
///    (`On <day>: ~X kcal in, protein Y g, sleep Z h, steps N`), nutrition
///    items summed into it;
///  - summary sleep and steps become daily signals.
/// The profile is not imported: the app has no stored location or units
/// setting yet. Only counts are printed, never content.
///
/// This tool never reads the old app's repository: any path inside
/// ~/Projects/illunis is refused. Pure Dart (no Flutter imports).
library;

import 'dart:convert';
import 'dart:io';

import 'package:illunis_client/app/memory_writer.dart' show isUserStatement, userStatementConfidence;
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/memory/memory_note.dart';
import 'package:illunis_client/memory/owner_import_bundle.dart';

const importSource = 'import:old_illunis';

/// Imported observations expire like the Hermes store's longest hypothesis.
const hypothesisLifetime = Duration(days: 180);
const journalHypothesisConfidence = 0.5;
const dayNoteConfidence = 0.5;

/// Journal text past this is cut (one entry stays one note).
const maxEntryChars = 500;

final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

class ImportResult {
  ImportResult(this.bundle, {required this.journal, required this.excluded, required this.dayNotes,
      required this.nutritionUsed, required this.nutritionExcluded, required this.skipped});
  final OwnerImportBundle bundle;
  final int journal, excluded, dayNotes, nutritionUsed, nutritionExcluded, skipped;

  Map<String, dynamic> toJson() => {
        'v': ownerImportVersion,
        'source': importSource,
        'notes': [for (final n in bundle.notes) n.toJson()],
        'signals': [for (final s in bundle.signals) s.toJson()],
      };

  String get counts => 'journal_notes=$journal excluded_from_ai=$excluded day_notes=$dayNotes '
      'signals=${bundle.signals.length} nutrition_used=$nutritionUsed '
      'nutrition_excluded=$nutritionExcluded skipped=$skipped';
}

String _cap(String text) {
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= maxEntryChars ? t : '${t.substring(0, maxEntryChars).trimRight()}...';
}

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

String _fmt(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

List<Map> _list(Map json, String key) {
  final v = json[key];
  if (v == null) return const [];
  if (v is! List) throw FormatException('$key must be a list');
  return v.whereType<Map>().toList();
}

/// The bundle for a decoded old-Illunis export. [now] sets the expiry of
/// imported observations. Throws [FormatException] for a wrong top level.
ImportResult parseOwnerExport(Object? json, {required DateTime now}) {
  if (json is! Map || json['journal'] is! List) {
    throw const FormatException('export must be an object with a journal list');
  }
  final expires = now.toUtc().add(hypothesisLifetime);
  final notes = <ImportedNote>[];
  final excludedIds = <String>{};
  var excluded = 0, skipped = 0;
  final journalRaw = json['journal'] as List;
  skipped += journalRaw.where((e) => e is! Map).length;

  for (final e in _list(json, 'journal')) {
    final id = e['id'], text = e['text'], at = e['at'] is String ? DateTime.tryParse(e['at'] as String) : null;
    if (e['excludedFromAi'] == true) {
      excluded++;
      if (id is String) excludedIds.add(id);
      continue;
    }
    if (id is! String || !_safeId.hasMatch(id) || text is! String || text.trim().isEmpty || at == null) {
      skipped++;
      continue;
    }
    final day = dayKey(at), body = _cap(text);
    final self = isUserStatement(body);
    notes.add(ImportedNote(
      id: 'old_illunis:j:$id',
      createdAt: at,
      note: MemoryNote(
        text: self ? 'User wrote on $day: $body' : 'Old journal, $day: $body',
        label: self ? MemoryLabel.note : MemoryLabel.observation,
        confidence: self ? userStatementConfidence : journalHypothesisConfidence,
        expiresAt: self ? null : expires,
        source: importSource,
      ),
    ));
  }
  final journal = notes.length;

  // Nutrition summed per day, without items logged from excluded entries.
  final kcal = <String, double>{}, protein = <String, double>{};
  var nutritionUsed = 0, nutritionExcluded = 0;
  for (final n in _list(json, 'nutrition')) {
    final day = n['day'], k = _num(n['kcal']);
    if (excludedIds.contains(n['journalEntryId'])) {
      nutritionExcluded++;
      continue;
    }
    if (parseDayKey(day) == null || k == null || k < 0) {
      skipped++;
      continue;
    }
    nutritionUsed++;
    kcal[day as String] = (kcal[day] ?? 0) + k;
    final p = _num(n['proteinG']);
    if (p != null && p >= 0) protein[day] = (protein[day] ?? 0) + p;
  }

  final summaries = <String, Map>{};
  for (final s in _list(json, 'summaries')) {
    if (parseDayKey(s['day']) == null) {
      skipped++;
    } else {
      summaries[s['day'] as String] = s;
    }
  }

  final signals = <DailySignals>[];
  var dayNotes = 0;
  for (final day in {...summaries.keys, ...kcal.keys}.toList()..sort()) {
    final s = summaries[day] ?? const {};
    final inKcal = kcal[day] ?? _num(s['intakeKcal']);
    final prot = kcal.containsKey(day) ? protein[day] : _num(s['proteinG']);
    final sleepH = _num(s['sleepHours']), steps = _num(s['steps']);
    final sig = DailySignals.fromJson({
      'day': day,
      'sleep_minutes': sleepH == null ? null : sleepH * 60,
      'steps': steps,
    });
    if (sig != null && !sig.isEmpty) signals.add(sig);
    final parts = [
      if (inKcal != null) '~${inKcal.round()} kcal in',
      if (prot != null) 'protein ${prot.round()} g',
      if (sig?.sleepMinutes != null) 'sleep ${_fmt(sig!.sleepMinutes! / 60)} h',
      if (sig?.steps != null) 'steps ${sig!.steps}',
    ];
    if (parts.isEmpty) continue;
    final date = parseDayKey(day)!;
    notes.add(ImportedNote(
      id: 'old_illunis:d:$day',
      createdAt: DateTime(date.year, date.month, date.day, 20),
      note: MemoryNote(
        text: 'On $day: ${parts.join(', ')}',
        label: MemoryLabel.observation,
        confidence: dayNoteConfidence,
        expiresAt: expires,
        source: importSource,
      ),
    ));
    dayNotes++;
  }

  notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return ImportResult(OwnerImportBundle(notes: notes, signals: signals),
      journal: journal, excluded: excluded, dayNotes: dayNotes, nutritionUsed: nutritionUsed,
      nutritionExcluded: nutritionExcluded, skipped: skipped);
}

/// True when [path] is inside the old app's repository (~/Projects/illunis),
/// which this tool must never read. ~/Projects/illunis-rework is allowed.
bool isRefusedSource(String path, {String? home}) {
  final h = home ?? Platform.environment['HOME'] ?? '';
  if (h.isEmpty) return false;
  final old = '$h/Projects/illunis';
  final abs = File(path).absolute.path;
  final norm = Uri.file(abs).normalizePath().toFilePath();
  return norm == old || norm.startsWith('$old/');
}

Future<int> run(List<String> args, {IOSink? out, DateTime? now}) async {
  final o = out ?? stdout;
  final outAt = args.indexOf('--out');
  final rest = [
    for (var i = 0; i < args.length; i++)
      if (outAt < 0 || (i != outAt && i != outAt + 1)) args[i],
  ];
  if (outAt < 0 || outAt + 1 >= args.length || rest.length != 1 || rest.single.startsWith('--')) {
    o.writeln('usage: dart run tool/import_owner_data.dart <export.json> --out <dir>');
    return 64;
  }
  final src = rest.single, dst = args[outAt + 1];
  if (isRefusedSource(src) || isRefusedSource(dst)) {
    o.writeln('import: refused (the old Illunis repository is never touched)');
    return 65;
  }
  final ImportResult result;
  try {
    var raw = await File(src).readAsString();
    if (raw.startsWith('﻿')) raw = raw.substring(1);
    result = parseOwnerExport(jsonDecode(raw), now: now ?? DateTime.now());
  } on FileSystemException {
    o.writeln('import: cannot read the export file');
    return 66;
  } on FormatException {
    o.writeln('import: the export is not in the expected format');
    return 65;
  }
  final dir = await Directory(dst).create(recursive: true);
  await File('${dir.path}/$ownerImportFile').writeAsString(jsonEncode(result.toJson()));
  o.writeln('import: wrote $ownerImportFile ${result.counts}');
  return 0;
}

Future<void> main(List<String> args) async => exitCode = await run(args);
