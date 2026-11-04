/// Saved log entries, on the phone only (build plan E7: never sent to
/// memory, never logged). One JSON value under [StoreKeys.logs]:
/// `{"v":1, "logs":{kind:{date:[envelope, ...]}}}` — a list per kind per
/// date. Entries are written only after the user's yes (log_capture.dart).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';
import 'log_entry.dart';

class LogStore extends ChangeNotifier {
  LogStore(this.store);
  final StateStore store;

  Map<LogKind, Map<String, List<LogEntry>>>? _cache;
  Future<void> _queue = Future.value();

  Future<Map<LogKind, Map<String, List<LogEntry>>>> _load() async {
    if (_cache case final c?) return c;
    final out = <LogKind, Map<String, List<LogEntry>>>{};
    final raw = await store.getString(StoreKeys.logs);
    Object? j;
    try {
      j = raw == null ? null : jsonDecode(raw);
    } on FormatException {
      j = null;
    }
    final logs = j is Map ? j['logs'] : null;
    if (logs is Map) {
      for (final MapEntry(key: k, value: byDate) in logs.entries) {
        final kind = LogKind.fromWire(k);
        if (kind == null || byDate is! Map) continue;
        for (final MapEntry(value: list) in byDate.entries) {
          if (list is! List) continue;
          for (final e in list) {
            // A stored entry is kept only under its own kind and date.
            final entry = LogEntry.fromJson(e);
            if (entry == null || entry.kind != kind) continue;
            ((out[kind] ??= {})[entry.date] ??= []).add(entry);
          }
        }
      }
    }
    return _cache = out;
  }

  /// The entries of [kind] on [date] (`yyyy-mm-dd`), in the order saved.
  Future<List<LogEntry>> forDay(LogKind kind, String date) async =>
      List.unmodifiable((await _load())[kind]?[date] ?? const <LogEntry>[]);

  /// Appends [entry] to its kind and date. The entry shows only once the
  /// write succeeded; a failed write fails this call only.
  Future<void> add(LogEntry entry) => _queue = _queue.catchError((Object _) {}).then((_) async {
        final all = await _load();
        final json = <String, Map<String, List<Object?>>>{
          for (final MapEntry(key: kind, value: byDate) in all.entries)
            kind.wire: {
              for (final MapEntry(key: date, value: list) in byDate.entries) date: [for (final e in list) e.toJson()],
            },
        };
        ((json[entry.kind.wire] ??= {})[entry.date] ??= []).add(entry.toJson());
        await store.setString(StoreKeys.logs, jsonEncode({'v': 1, 'logs': json}));
        ((all[entry.kind] ??= {})[entry.date] ??= []).add(entry);
        notifyListeners();
      });
}
