/// Daily signals from an owner import (tool/import_owner_data.dart), kept on
/// the phone under [importedSignalsKey] beside the live Health Connect read.
/// In the analysis a Health Connect day wins over an imported one.
library;

import 'dart:convert';

import '../app/persistence.dart';
import 'daily_signals.dart';

/// Private store key; holds the user's own data and is never logged.
const importedSignalsKey = 'health_imported_signals';

/// Older imported days than this are not kept.
const importedSignalsMax = 400;

class ImportedSignalsStore {
  ImportedSignalsStore(this.store);
  final StateStore store;

  /// Every kept day, oldest first.
  Future<List<DailySignals>> all() async {
    final raw = await store.getString(importedSignalsKey);
    if (raw == null) return [];
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return [];
    }
    final list = j is Map ? j['signals'] : null;
    if (list is! List) return [];
    return [for (final s in list) ?DailySignals.fromJson(s)]..sort((a, b) => a.day.compareTo(b.day));
  }

  /// Adds [days]; a day already kept is replaced. Returns how many days
  /// changed (0 when the same import runs again).
  Future<int> merge(Iterable<DailySignals> days) async {
    final byDay = {for (final s in await all()) s.day: s};
    var changed = 0;
    for (final d in days) {
      if (d.isEmpty || byDay[d.day] == d) continue;
      byDay[d.day] = d;
      changed++;
    }
    if (changed == 0) return 0;
    final kept = [for (final k in byDay.keys.toList()..sort()) byDay[k]!];
    if (kept.length > importedSignalsMax) kept.removeRange(0, kept.length - importedSignalsMax);
    await store.setString(importedSignalsKey, jsonEncode({'v': 1, 'signals': [for (final s in kept) s.toJson()]}));
    return changed;
  }
}
