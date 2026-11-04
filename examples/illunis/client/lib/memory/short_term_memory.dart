/// Short-term memory on the phone (docs/DESIGN.md
/// section 2): the current conversation's turns plus the summaries of the last
/// [ShortTermMemory.maxSummaries] sessions (5 by default). Kept in private
/// app storage under [StoreKeys.shortTermMemory].
///
/// A session ends when [ShortTermMemory.endSession] is called (the app does
/// this when it goes to the background) or when a new turn comes more than
/// [ShortTermMemory.sessionGap] after the last one. Its turns are then sent
/// once to POST /session/summary and only the returned summary is kept. A
/// failed summary keeps the turns (capped) so the next end retries.
///
/// Logs carry fixed codes only, never a turn or a summary.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';

const defaultMaxSummaries = 5;
const defaultMaxTurns = 20;
const defaultSessionGap = Duration(minutes: 30);
const _maxTurnChars = 600;
const _maxSummaryChars = 800;

/// One conversation turn: [role] is `user` or `assistant`.
class SessionTurn {
  const SessionTurn(this.role, this.text);
  final String role;
  final String text;

  static const user = 'user';
  static const assistant = 'assistant';

  Map<String, dynamic> toJson() => {'role': role, 'text': text};

  static SessionTurn? fromJson(Object? j) {
    if (j is! Map) return null;
    final r = j['role'], t = j['text'];
    if ((r != user && r != assistant) || t is! String || t.trim().isEmpty) return null;
    return SessionTurn(r as String, t);
  }

  @override
  bool operator ==(Object other) => other is SessionTurn && other.role == role && other.text == text;
  @override
  int get hashCode => Object.hash(role, text);
}

/// A finished session as kept on the phone.
class SessionSummary {
  const SessionSummary({required this.text, required this.startedAt, required this.endedAt});
  final String text;
  final DateTime startedAt;
  final DateTime endedAt;

  Map<String, dynamic> toJson() => {
        'text': text,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt.toUtc().toIso8601String(),
      };

  static SessionSummary? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['text'], s = j['started_at'], e = j['ended_at'];
    final start = s is String ? DateTime.tryParse(s) : null;
    final end = e is String ? DateTime.tryParse(e) : null;
    if (t is! String || t.trim().isEmpty || start == null || end == null) return null;
    return SessionSummary(text: t, startedAt: start, endedAt: end);
  }
}

/// The `short_term` field sent with /turn and /reply:
/// `{summaries: [text, ...], turns: [{role, text}, ...]}`, oldest first.
class ShortTermContext {
  const ShortTermContext({this.summaries = const [], this.turns = const []});
  final List<String> summaries;
  final List<SessionTurn> turns;

  bool get isEmpty => summaries.isEmpty && turns.isEmpty;

  Map<String, dynamic> toJson() => {
        'summaries': summaries,
        'turns': [for (final t in turns) t.toJson()],
      };
}

/// Sends one session to POST /session/summary and returns its summary.
typedef SessionSummariser = Future<String> Function(
    {required List<SessionTurn> turns, required DateTime startedAt, required DateTime endedAt});

String _cap(String text, int max) {
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= max ? t : '${t.substring(0, max).trimRight()}...';
}

class ShortTermMemory {
  ShortTermMemory({
    required this.store,
    required this.summarise,
    int maxSummaries = defaultMaxSummaries,
    this.maxTurns = defaultMaxTurns,
    this.sessionGap = defaultSessionGap,
    DateTime Function()? clock,
    void Function(String line)? log,
  })  : _maxSummaries = maxSummaries < 1 ? 1 : maxSummaries,
        _clock = clock ?? DateTime.now,
        _log = log ?? debugPrint;

  final StateStore store;
  final SessionSummariser summarise;
  final int maxTurns;
  final Duration sessionGap;
  final DateTime Function() _clock;
  final void Function(String) _log;

  int _maxSummaries;
  final _turns = <SessionTurn>[];
  final _summaries = <SessionSummary>[];
  DateTime? _startedAt;
  DateTime? _lastTurnAt;
  Future<void> _queue = Future.value();

  List<SessionTurn> get turns => List.unmodifiable(_turns);
  List<SessionSummary> get summaries => List.unmodifiable(_summaries);
  DateTime? get startedAt => _startedAt;

  /// How many session summaries are kept (at least 1). Lowering it drops the
  /// oldest at once.
  int get maxSummaries => _maxSummaries;
  set maxSummaries(int n) {
    _maxSummaries = n < 1 ? 1 : n;
    _trimSummaries();
    _queue = _queue.then((_) => _save());
  }

  void _trimSummaries() {
    if (_summaries.length > _maxSummaries) _summaries.removeRange(0, _summaries.length - _maxSummaries);
  }

  /// Completes when every queued change is saved.
  Future<void> get settled => _queue;

  Future<void> load() async {
    final raw = await store.getString(StoreKeys.shortTermMemory);
    if (raw == null) return;
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (j is! Map) return;
    _turns
      ..clear()
      ..addAll([for (final t in (j['turns'] as List? ?? const [])) ?SessionTurn.fromJson(t)]);
    _summaries
      ..clear()
      ..addAll([for (final s in (j['summaries'] as List? ?? const [])) ?SessionSummary.fromJson(s)]);
    _trimSummaries();
    _startedAt = j['started_at'] is String ? DateTime.tryParse(j['started_at'] as String) : null;
    _lastTurnAt = j['last_turn_at'] is String ? DateTime.tryParse(j['last_turn_at'] as String) : null;
    if (_turns.isEmpty) _startedAt = _lastTurnAt = null;
  }

  Future<void> _save() => store.setString(
      StoreKeys.shortTermMemory,
      jsonEncode({
        'v': 1,
        'turns': [for (final t in _turns) t.toJson()],
        'summaries': [for (final s in _summaries) s.toJson()],
        'started_at': ?_startedAt?.toUtc().toIso8601String(),
        'last_turn_at': ?_lastTurnAt?.toUtc().toIso8601String(),
      }));

  Future<void> _serial(Future<void> Function() f) {
    final next = _queue.then((_) => f());
    _queue = next.catchError((Object e) => _log('memory: short_term_failed error=${e.runtimeType}'));
    return _queue;
  }

  /// Adds one completed exchange (the user's words and Illunis's answer).
  Future<void> addExchange({required String user, required String assistant}) => _serial(() async {
        final u = _cap(user, _maxTurnChars), a = _cap(assistant, _maxTurnChars);
        if (u.isEmpty) return;
        final now = _clock();
        _startedAt ??= now;
        _lastTurnAt = now;
        _turns.add(SessionTurn(SessionTurn.user, u));
        if (a.isNotEmpty) _turns.add(SessionTurn(SessionTurn.assistant, a));
        if (_turns.length > maxTurns) _turns.removeRange(0, _turns.length - maxTurns);
        await _save();
      });

  /// Ends the session first when the last turn is older than [sessionGap].
  Future<void> rollOverIfStale() {
    final last = _lastTurnAt;
    if (last == null || _clock().difference(last) <= sessionGap) return _queue;
    return endSession();
  }

  /// Summarises and closes the current session. Nothing to do without turns.
  Future<void> endSession() => _serial(() async {
        final start = _startedAt, end = _lastTurnAt;
        if (_turns.isEmpty || start == null || end == null) return;
        final String text;
        try {
          text = _cap(await summarise(turns: List.of(_turns), startedAt: start, endedAt: end), _maxSummaryChars);
        } catch (e) {
          _log('memory: session_summary_failed');
          return; // Turns stay for the next attempt.
        }
        if (text.isNotEmpty) {
          _summaries.add(SessionSummary(text: text, startedAt: start, endedAt: end));
          _trimSummaries();
        } else {
          _log('memory: session_summary_empty');
        }
        _turns.clear();
        _startedAt = _lastTurnAt = null;
        await _save();
      });

  /// The `short_term` field for /turn and /reply.
  ShortTermContext context() =>
      ShortTermContext(summaries: [for (final s in _summaries) s.text], turns: List.of(_turns));

  /// Summaries as one string (council `context.short_term_summary`).
  String summaryText() => _summaries.map((s) => s.text).join('\n');
}
