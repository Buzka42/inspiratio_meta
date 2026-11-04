/// Mood, energy and sleep check-ins, 1 to 5. One spoken question
/// after the morning digest; the answer is parsed from words or numbers
/// ("four three five", "mood 4, energy 3, sleep 2", "all fours") and stored
/// on the phone under [StoreKeys.checkIns], one entry per local day.
///
/// Logs carry codes only, never an answer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';
import 'daily_signals.dart';

/// Older check-ins are dropped.
const checkInKeepDays = 60;

class CheckIn {
  const CheckIn({required this.day, this.mood, this.energy, this.sleep});
  final String day;
  final int? mood;
  final int? energy;
  final int? sleep;

  bool get isEmpty => mood == null && energy == null && sleep == null;

  Map<String, dynamic> toJson() => {'day': day, 'mood': mood, 'energy': energy, 'sleep': sleep};

  static int? _score(Object? v) => v is int && v >= 1 && v <= 5 ? v : null;

  static CheckIn? fromJson(Object? j) {
    if (j is! Map || parseDayKey(j['day']) == null) return null;
    final c = CheckIn(
        day: j['day'] as String,
        mood: _score(j['mood']),
        energy: _score(j['energy']),
        sleep: _score(j['sleep']));
    return c.isEmpty ? null : c;
  }

  @override
  bool operator ==(Object other) =>
      other is CheckIn && other.day == day && other.mood == mood && other.energy == energy && other.sleep == sleep;
  @override
  int get hashCode => Object.hash(day, mood, energy, sleep);
}

// ---- Parsing ----------------------------------------------------------------

const _numbers = {
  '1': 1, '2': 2, '3': 3, '4': 4, '5': 5,
  'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
  'ones': 1, 'twos': 2, 'threes': 3, 'fours': 4, 'fives': 5,
  // Polish.
  'jeden': 1, 'jedna': 1, 'jedynka': 1, 'dwa': 2, 'dwie': 2, 'dwójka': 2, 'trzy': 3, 'trójka': 3,
  'cztery': 4, 'czwórka': 4, 'pięć': 5, 'piątka': 5,
};

enum _Slot { mood, energy, sleep }

const _labels = {
  'mood': _Slot.mood, 'feeling': _Slot.mood, 'nastrój': _Slot.mood, 'humor': _Slot.mood,
  'energy': _Slot.energy, 'energia': _Slot.energy, 'energii': _Slot.energy,
  'sleep': _Slot.sleep, 'slept': _Slot.sleep, 'sleeping': _Slot.sleep, 'sen': _Slot.sleep, 'spałem': _Slot.sleep,
  'spałam': _Slot.sleep,
};

const _allWords = {'all', 'everything', 'each', 'wszystko'};
const _declines = {
  'skip', 'no', 'nope', 'not now', 'no thanks', 'no thank you', 'later', 'pass', 'none', 'nie', 'pomiń',
};

final _outOfFive = RegExp(r'\b(?:out of|of|na|z) (?:five|5|pięciu)\b');
final _slashFive = RegExp(r'(\d)\s*/\s*5');
final _wordRe = RegExp(r"[\p{L}\p{N}]+", unicode: true);

String _normalise(String raw) =>
    raw.toLowerCase().replaceAllMapped(_slashFive, (m) => m[1]!).replaceAll(_outOfFive, ' ');

/// True for "skip", "no", "not now" and the like.
bool isCheckInDecline(String raw) =>
    _declines.contains(_wordRe.allMatches(raw.toLowerCase()).map((m) => m[0]).join(' '));

/// The three scores in [raw] for [day], or null when none can be read.
/// Labelled numbers go to their label; the rest fill mood, energy, sleep in
/// order. "all fours" (one number with "all") sets all three. Numbers
/// outside 1 to 5 are ignored.
CheckIn? parseCheckIn(String raw, {required String day}) {
  final words = [for (final m in _wordRe.allMatches(_normalise(raw))) m[0]!];
  final got = <_Slot, int>{};
  final loose = <int>[];
  _Slot? pending;
  var all = false;
  for (final w in words) {
    if (_allWords.contains(w)) all = true;
    final label = _labels[w];
    if (label != null) {
      pending = label;
      continue;
    }
    final n = _numbers[w];
    if (n == null) continue;
    if (pending != null && !got.containsKey(pending)) {
      got[pending] = n;
    } else {
      loose.add(n);
    }
    pending = null;
  }
  if (all && got.isEmpty && loose.length == 1) {
    for (final s in _Slot.values) {
      got[s] = loose.single;
    }
    loose.clear();
  }
  for (final s in _Slot.values) {
    if (!got.containsKey(s) && loose.isNotEmpty) got[s] = loose.removeAt(0);
  }
  final c = CheckIn(day: day, mood: got[_Slot.mood], energy: got[_Slot.energy], sleep: got[_Slot.sleep]);
  return c.isEmpty ? null : c;
}

// ---- Storage ----------------------------------------------------------------

class CheckInStore {
  CheckInStore(this.store, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final StateStore store;
  final DateTime Function() _clock;

  /// Every kept check-in, oldest first.
  Future<List<CheckIn>> all() async {
    final raw = await store.getString(StoreKeys.checkIns);
    if (raw == null) return [];
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return [];
    }
    final list = j is Map ? j['checkins'] : null;
    if (list is! List) return [];
    return [for (final c in list) ?CheckIn.fromJson(c)]..sort((a, b) => a.day.compareTo(b.day));
  }

  Future<CheckIn?> forDay(String day) async => (await all()).where((c) => c.day == day).firstOrNull;

  /// Saves [c], replacing that day's earlier answer; drops days older than
  /// [checkInKeepDays].
  Future<void> save(CheckIn c) async {
    final now = _clock();
    final oldest = dayKey(DateTime(now.year, now.month, now.day - (checkInKeepDays - 1)));
    final kept = [
      for (final e in await all())
        if (e.day != c.day && e.day.compareTo(oldest) >= 0) e,
      c,
    ]..sort((a, b) => a.day.compareTo(b.day));
    await store.setString(StoreKeys.checkIns, jsonEncode({'v': 1, 'checkins': [for (final e in kept) e.toJson()]}));
  }
}

// ---- Spoken question --------------------------------------------------------

abstract final class CheckInPrompt {
  static const ask = 'One quick question: from one to five, how are your mood, your energy, '
      'and your sleep last night?';
  static const reask = 'Please say three numbers from one to five, for mood, energy and sleep.';

  /// [reask] with typed wording (voice off).
  static const typedReask = 'Please type three numbers from one to five, for mood, energy and sleep.';
  static const declined = 'All right.';
  static const gaveUp = 'No problem, we can try again tomorrow.';
  static String saved(CheckIn c) {
    final parts = [
      if (c.mood != null) 'mood ${c.mood}',
      if (c.energy != null) 'energy ${c.energy}',
      if (c.sleep != null) 'sleep ${c.sleep}',
    ];
    return 'Thank you. I noted ${parts.join(', ')}.';
  }
}

/// Asks the check-in once per day and takes the answer through the app's
/// setup hook ([claim]).
class CheckInSession {
  CheckInSession({
    required this.checkIns,
    required this.speak,
    this.listen,
    this.typed = false,
    DateTime Function()? clock,
    void Function(String line)? log,
  })  : _clock = clock ?? DateTime.now,
        _log = log ?? debugPrint;

  final CheckInStore checkIns;
  final Future<void> Function(String text) speak;
  final void Function()? listen;

  /// Typed wording (voice off): the re-ask says "type" instead of "say".
  final bool typed;
  final DateTime Function() _clock;
  final void Function(String) _log;

  String? _askingDay;
  var _reasked = false;
  Future<void> _queue = Future.value();

  bool get asking => _askingDay != null;
  Future<void> get settled => _queue;

  /// Asks today's question unless today already has a check-in. Called after
  /// the morning digest has finished speaking.
  Future<void> ask() {
    _queue = _queue.then((_) async {
      try {
        final day = dayKey(_clock());
        if (asking || await checkIns.forDay(day) != null) return;
        _askingDay = day;
        _reasked = false;
        await speak(CheckInPrompt.ask);
        if (asking) listen?.call();
      } catch (e) {
        _log('checkin: ask_failed error=${e.runtimeType}');
      }
    });
    return _queue;
  }

  /// Takes the transcript while the question is open.
  bool claim(String text) {
    if (!asking) return false;
    _queue = _queue.then((_) => _answer(text));
    return true;
  }

  Future<void> _answer(String text) async {
    final day = _askingDay;
    if (day == null) return;
    try {
      if (isCheckInDecline(text)) {
        _askingDay = null;
        _log('checkin: declined');
        return await speak(CheckInPrompt.declined);
      }
      final c = parseCheckIn(text, day: day);
      if (c == null) {
        if (_reasked) {
          _askingDay = null;
          _log('checkin: unreadable');
          return await speak(CheckInPrompt.gaveUp);
        }
        _reasked = true;
        _log('checkin: reask');
        await speak(typed ? CheckInPrompt.typedReask : CheckInPrompt.reask);
        if (asking) listen?.call();
        return;
      }
      _askingDay = null;
      await checkIns.save(c);
      _log('checkin: saved');
      await speak(CheckInPrompt.saved(c));
    } catch (e) {
      _askingDay = null;
      _log('checkin: failed error=${e.runtimeType}');
    }
  }
}
