/// The default long-term memory: notes kept on the phone in private app
/// storage ([StateStore], one JSON string under [StoreKeys.longTermMemory]).
/// Recall is keyword overlap; expired notes are never recalled or counted
/// and are removed from the store on the next write (or [purgeExpired]). Nothing here touches the network.
library;

import 'dart:convert';

import '../app/persistence.dart';
import 'memory_backend.dart';
import 'memory_note.dart';
import 'owner_import_bundle.dart';

/// Oldest notes go first past this many.
const defaultMaxLocalNotes = 300;

/// Words too common to count as a match (English and Polish).
const _stopWords = {
  'the', 'and', 'for', 'are', 'was', 'were', 'you', 'your', 'with', 'that', 'this', 'what', 'have',
  'has', 'had', 'but', 'not', 'can', 'could', 'should', 'would', 'about', 'from', 'they', 'them',
  'how', 'why', 'when', 'where', 'who', 'which', 'did', 'does', 'will', 'just', 'into', 'some',
  'any', 'all', 'too', 'very', 'than', 'then', 'there', 'their', 'its', 'our', 'out', 'get',
  'user', 'said', 'asked', 'illunis', 'answered',
  'do', 'my', 'me', 'is', 'of', 'in', 'on', 'at', 'it', 'to', 'an', 'or', 'be', 'so', 'if', 'we', 'am', 'im',
  'jak', 'czy', 'nie', 'jest', 'się', 'mnie', 'dla', 'ale', 'też', 'już', 'tak', 'ten',
};

final _wordRe = RegExp(r"[\p{L}\p{N}]+", unicode: true);

/// Lower-case content words of [text], two or more letters, stop words out.
Set<String> keywords(String text) => {
      for (final m in _wordRe.allMatches(text.toLowerCase()))
        if (m[0]!.length >= 2 && !_stopWords.contains(m[0])) m[0]!,
    };

/// Overlap of [query] words with [note] words: 1 per exact word, 0.6 when
/// one word starts the other and both have four or more letters ("sleep",
/// "sleeping").
double keywordScore(Set<String> query, Set<String> note) {
  var s = 0.0;
  for (final q in query) {
    if (note.contains(q)) {
      s += 1;
    } else if (q.length >= 4 && note.any((w) => w.length >= 4 && (w.startsWith(q) || q.startsWith(w)))) {
      s += 0.6;
    }
  }
  return s;
}

class _Stored {
  _Stored(this.note, this.createdAt, {this.importId});
  final MemoryNote note;
  final DateTime createdAt;

  /// Set for notes from an owner import ([LocalMemoryBackend.importNotes]).
  final String? importId;

  Map<String, dynamic> toJson() => {
        ...note.toJson(),
        'created_at': createdAt.toUtc().toIso8601String(),
        if (importId != null) 'import_id': importId,
      };

  static _Stored? fromJson(Object? j) {
    final n = MemoryNote.fromJson(j);
    if (n == null || j is! Map) return null;
    final c = j['created_at'], id = j['import_id'];
    final created = c is String ? DateTime.tryParse(c) : null;
    return created == null ? null : _Stored(n, created, importId: id is String ? id : null);
  }
}

String _textKey(String text) => text.trim().toLowerCase();

class LocalMemoryBackend implements MemoryBackend {
  LocalMemoryBackend(this.store, {DateTime Function()? clock, this.maxNotes = defaultMaxLocalNotes})
      : _clock = clock ?? DateTime.now;

  final StateStore store;
  final int maxNotes;
  final DateTime Function() _clock;

  List<_Stored>? _notes;
  Future<void> _queue = Future.value();

  @override
  String get id => 'phone';

  bool _live(_Stored s, DateTime now) {
    final e = s.note.expiresAt;
    return e == null || e.isAfter(now);
  }

  Future<List<_Stored>> _load() async {
    final cached = _notes;
    if (cached != null) return cached;
    final out = <_Stored>[];
    final raw = await store.getString(StoreKeys.longTermMemory);
    if (raw != null) {
      try {
        final j = jsonDecode(raw);
        final list = j is Map ? j['notes'] : null;
        if (list is List) out.addAll(list.map(_Stored.fromJson).whereType<_Stored>());
      } on FormatException {
        // Unreadable store: start empty; the next write replaces it.
      }
    }
    return _notes = out;
  }

  Future<void> _save(List<_Stored> notes) => store.setString(
      StoreKeys.longTermMemory, jsonEncode({'v': 1, 'notes': [for (final n in notes) n.toJson()]}));

  /// Runs [f] after every earlier call, so unawaited writes never interleave.
  Future<T> _serial<T>(Future<T> Function() f) {
    final next = _queue.then((_) => f());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// The same text again replaces the older note (newer time, its expiry).
  @override
  Future<void> write(MemoryNote note) => _serial(() async {
        final now = _clock();
        final key = _textKey(note.text);
        final notes = (await _load())
            .where((s) => _live(s, now) && _textKey(s.note.text) != key)
            .toList()
          ..add(_Stored(note, now));
        if (notes.length > maxNotes) notes.removeRange(0, notes.length - maxNotes);
        _notes = notes;
        await _save(notes);
      });

  /// Adds imported notes with their own creation times, oldest first. A note
  /// whose id or text is already stored, or that has expired, is skipped, so
  /// a second import adds nothing. Returns how many were added.
  Future<int> importNotes(Iterable<ImportedNote> imported) => _serial(() async {
        final now = _clock();
        final notes = (await _load()).where((s) => _live(s, now)).toList();
        final ids = {for (final s in notes) ?s.importId};
        final texts = {for (final s in notes) _textKey(s.note.text)};
        var added = 0;
        for (final i in imported) {
          final e = i.note.expiresAt;
          if (ids.contains(i.id) || !texts.add(_textKey(i.note.text)) || (e != null && !e.isAfter(now))) continue;
          ids.add(i.id);
          notes.add(_Stored(i.note, i.createdAt, importId: i.id));
          added++;
        }
        if (added == 0) return 0;
        // Stable sort keeps same-time notes in write order.
        final ordered = [for (var k = 0; k < notes.length; k++) (k, notes[k])]
          ..sort((a, b) {
            final c = a.$2.createdAt.compareTo(b.$2.createdAt);
            return c != 0 ? c : a.$1.compareTo(b.$1);
          });
        final kept = [for (final o in ordered) o.$2];
        if (kept.length > maxNotes) kept.removeRange(0, kept.length - maxNotes);
        _notes = kept;
        await _save(kept);
        return added;
      });

  /// Import ids and lower-cased texts of the notes in [store] now, read past
  /// any cache: what the loader checks before it deletes a bundle.
  static Future<Set<String>> storedKeys(StateStore store) async {
    final fresh = LocalMemoryBackend(store);
    return {
      for (final s in await fresh._load()) ...[?s.importId, _textKey(s.note.text)],
    };
  }

  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) => _serial(() async {
        if (k <= 0) return const <RecalledMemory>[];
        final now = _clock();
        final q = keywords(query);
        if (q.isEmpty) return const <RecalledMemory>[];
        final scored = <({_Stored s, double score})>[
          for (final s in await _load())
            if (_live(s, now)) (s: s, score: keywordScore(q, keywords(s.note.text)) * (0.5 + s.note.confidence / 2)),
        ].where((e) => e.score > 0).toList()
          ..sort((a, b) {
            final c = b.score.compareTo(a.score);
            return c != 0 ? c : b.s.createdAt.compareTo(a.s.createdAt);
          });
        return [for (final e in scored.take(k)) e.s.note.toRecalled()];
      });

  @override
  Future<MemorySummary> summary() => _serial(() async {
        final now = _clock();
        return MemorySummary(backend: id, noteCount: (await _load()).where((s) => _live(s, now)).length);
      });

  /// Drops expired notes from the store now. Returns how many went.
  Future<int> purgeExpired() => _serial(() async {
        final now = _clock();
        final all = await _load();
        final kept = all.where((s) => _live(s, now)).toList();
        final removed = all.length - kept.length;
        if (removed > 0) {
          _notes = kept;
          await _save(kept);
        }
        return removed;
      });
}
