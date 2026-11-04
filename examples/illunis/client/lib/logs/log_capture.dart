/// Typed capture for one log kind (build plan B6). The user types a line;
/// the phone calls POST /log/parse, shows the parsed entry and asks
/// "Save? Yes / No". Only a yes (tapped or typed) writes it to [LogStore];
/// a no discards it. Crisis text shows the fixed referral. A rejected
/// answer or a failed call shows a short message, never the raw code.
/// Logs carry fixed codes only, never the text or the entry.
library;

import 'package:flutter/foundation.dart';

import '../app/server_port.dart';
import '../voice/confirm_phrase.dart';
import 'log_entry.dart';
import 'log_store.dart';

sealed class CaptureState {
  const CaptureState();
}

/// Waiting for a line.
class CaptureIdle extends CaptureState {
  const CaptureIdle();
}

/// The parse call is in flight.
class CaptureReading extends CaptureState {
  const CaptureReading();
}

/// Parsed; waiting for Save? Yes / No. [checkedAgainst] is the title of the
/// source a match was checked against, shown as one line.
class CapturePreview extends CaptureState {
  const CapturePreview(this.entry, {this.checkedAgainst});
  final LogEntry entry;
  final String? checkedAgainst;
}

/// A food calorie mismatch: [choices] are the rows still to pick (each keeps
/// the user's number or uses the found one). After the last pick the entry
/// moves to [CapturePreview]. Nothing is saved before that.
class CaptureChoice extends CaptureState {
  const CaptureChoice(this.entry, this.choices, {this.checkedAgainst});
  final LogEntry entry;
  final List<FoodChoice> choices;
  final String? checkedAgainst;
}

/// A short line for the user: saved, not saved, or why nothing was parsed.
class CaptureMessage extends CaptureState {
  const CaptureMessage(this.text);
  final String text;
}

/// Crisis wording: the server's fixed referral, nothing parsed.
class CaptureCrisis extends CaptureState {
  const CaptureCrisis(this.referral);
  final String referral;
}

abstract final class CaptureText {
  static const savePrompt = 'Save?';
  static const saved = 'Saved.';
  static const discarded = 'Not saved.';
  static const reading = 'Reading your log…';
  static const unavailable = 'Logging is not available right now. Please try again later.';
  static const saveFailed = 'That could not be saved on this phone. Please try again.';
  static const verify = 'Please check this. The numbers differ from the source.';

  /// The line under the preview when a source matched.
  static String checkedAgainst(String title) => 'Checked against $title';

  /// A typed line the user can copy, per kind.
  static const examples = {
    LogKind.food: 'porridge 80 g and a coffee for breakfast',
    LogKind.activity: 'walked 40 min, 3.2 km',
    LogKind.strength: 'squat 3x5 at 100 kg',
    LogKind.run: '5 km in 26 min, splits 5:10 5:20 5:15 5:05 5:10',
    LogKind.cardio: 'rowing 30 min, average HR 140, max 165',
  };

  /// The short message for a fixed rejection code.
  static String forCode(String code, LogKind kind) => switch (code) {
        'number_not_in_text' => 'I can only keep numbers you wrote. Please write the numbers in your line.',
        'out_of_range' => 'One of those numbers looks out of range. Please check it and try again.',
        'empty_entry' => 'I found nothing to log there. Try naming what you did.',
        _ => 'I could not read that as a ${kind.wire} log. Try a line like "${examples[kind]}".',
      };
}

/// `rir` or `rpe` when the user wrote that scale in a strength line
/// (writing it is the choice to log it); otherwise [fallback].
String effortFor(LogKind kind, String text, String fallback) {
  if (kind != LogKind.strength) return 'none';
  final t = text.toLowerCase();
  if (RegExp(r'\brir\b|reps? in reserve').hasMatch(t)) return 'rir';
  if (RegExp(r'\brpe\b').hasMatch(t)) return 'rpe';
  return fallback;
}

/// `mine` or `source` for the whole choice at once; null for anything else.
enum ChoiceAnswer { mine, source }

ChoiceAnswer? parseChoiceAnswer(String raw) {
  final words = spokenWords(raw);
  if (words.length != 1) return null;
  return switch (words.first) {
    'mine' => ChoiceAnswer.mine,
    'source' => ChoiceAnswer.source,
    _ => null,
  };
}

/// The title of the first match in a parse envelope's `check`, if any.
String? checkedAgainstOf(Map<String, dynamic> env) {
  final check = env['check'];
  if (check is! List) return null;
  for (final c in check) {
    if (c is Map && c['status'] == 'match' && c['source_title'] is String) {
      final t = (c['source_title'] as String).trim();
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}

/// [e] with each found kcal put on its item (same name, quantity, unit).
LogEntry _useFound(LogEntry e, Iterable<FoodChoice> found) {
  if (e is! FoodEntry) return e;
  final items = [...e.items];
  for (final c in found) {
    final i = items[c.itemIndex];
    // The source's figure, not one the user stated: it keeps the "est." label.
    items[c.itemIndex] =
        FoodItem(name: i.name, quantity: i.quantity, unit: i.unit, kcal: c.foundValue.toDouble(), estimated: true);
  }
  return FoodEntry(date: e.date, source: e.source, meal: e.meal, items: items);
}

class LogCapture extends ChangeNotifier {
  LogCapture({
    required this.kind,
    required this.server,
    required this.store,
    required this.date,
    this.effort = 'none',
    void Function(String line)? log,
  }) : _log = log ?? debugPrint;

  final LogKind kind;
  final ServerPort server;
  final LogStore store;

  /// The day the entry is for (`yyyy-mm-dd`), read at each parse.
  final String Function() date;

  /// The user's standing effort pref: `none`, `rir` or `rpe`.
  final String effort;
  final void Function(String line) _log;

  CaptureState _state = const CaptureIdle();
  CaptureState get state => _state;
  bool _disposed = false;

  /// Bumped by each parse and by [reset]; a parse whose number is stale
  /// when it lands is dropped.
  int _seq = 0;

  void _set(CaptureState s) {
    _state = s;
    if (!_disposed) notifyListeners();
  }

  /// A typed line. With a preview open, a yes saves and a no discards;
  /// with a choice open, "mine" or "source" answers every row. Anything else
  /// is a new line (the open entry is dropped unsaved).
  Future<void> submit(String text) async {
    final t = text.trim();
    if (t.isEmpty || _state is CaptureReading) return;
    if (_state is CapturePreview) {
      final a = parseOfferAnswer(t);
      if (a != null) return answer(a);
    }
    final s = _state;
    if (s is CaptureChoice) {
      final c = parseChoiceAnswer(t);
      if (c != null) return chooseAll(useFound: c == ChoiceAnswer.source);
    }
    await _parse(t);
  }

  /// One row's pick: [useFound] uses the source's number, otherwise the
  /// user's own number is kept.
  void chooseOne(FoodChoice c, {required bool useFound}) {
    final s = _state;
    if (s is! CaptureChoice || !s.choices.contains(c)) return;
    _settle(s, {c: useFound});
  }

  /// Every open row at once.
  void chooseAll({required bool useFound}) {
    final s = _state;
    if (s is! CaptureChoice) return;
    _settle(s, {for (final c in s.choices) c: useFound});
  }

  /// Drops the open choice unsaved.
  void discardChoice() {
    if (_state is! CaptureChoice) return;
    _log('log: discarded kind=${kind.wire}');
    _set(const CaptureMessage(CaptureText.discarded));
  }

  /// Applies the picks; the entry goes to the preview after the last one.
  void _settle(CaptureChoice s, Map<FoodChoice, bool> picks) {
    final found = [for (final e in picks.entries) if (e.value) e.key];
    final entry = _useFound(s.entry, found);
    final rest = [for (final c in s.choices) if (!picks.containsKey(c)) c];
    _log('log: chose kind=${kind.wire} n=${picks.length}');
    if (rest.isEmpty) return _set(CapturePreview(entry, checkedAgainst: s.checkedAgainst));
    _set(CaptureChoice(entry, rest, checkedAgainst: s.checkedAgainst));
  }

  /// Drops whatever is open (a preview or a choice) unsaved and goes back to
  /// waiting, with no message. A parse still in flight is dropped when it
  /// lands.
  void reset() {
    if (_state is CaptureIdle) return;
    _seq++;
    if (_state is CapturePreview || _state is CaptureChoice) _log('log: discarded kind=${kind.wire}');
    _set(const CaptureIdle());
  }

  /// The Save? answer. Does nothing without a preview.
  Future<void> answer(bool yes) async {
    final s = _state;
    if (s is! CapturePreview) return;
    if (!yes) {
      _log('log: discarded kind=${kind.wire}');
      return _set(const CaptureMessage(CaptureText.discarded));
    }
    try {
      await store.add(s.entry);
    } catch (_) {
      _log('log: save_failed kind=${kind.wire}');
      return _set(const CaptureMessage(CaptureText.saveFailed));
    }
    _log('log: saved kind=${kind.wire}');
    _set(const CaptureMessage(CaptureText.saved));
  }

  Future<void> _parse(String text) async {
    final seq = ++_seq;
    _set(const CaptureReading());
    final LogParseResult r;
    try {
      r = await server.parseLog(kind.wire, text, prefs: {'effort': effortFor(kind, text, effort)}, date: date());
    } catch (_) {
      if (seq != _seq) return;
      _log('log: parse_failed kind=${kind.wire}');
      return _set(const CaptureMessage(CaptureText.unavailable));
    }
    if (_disposed || seq != _seq) return;
    if (r.crisis) {
      _log('log: crisis');
      return _set(CaptureCrisis(r.referral!));
    }
    final env = r.envelope;
    if (env == null) {
      final pending = r.pending;
      if (pending == null) {
        _log('log: rejected kind=${kind.wire} code=${r.code}');
        return _set(CaptureMessage(CaptureText.forCode(r.code ?? '', kind)));
      }
      return _startChoice(pending, r.choices);
    }
    final entry = LogEntry.fromJson(env);
    if (entry == null || entry.kind != kind) {
      _log('log: bad_envelope kind=${kind.wire}');
      return _set(CaptureMessage(CaptureText.forCode('bad_field', kind)));
    }
    _log('log: parsed kind=${kind.wire}');
    _set(CapturePreview(entry, checkedAgainst: checkedAgainstOf(env)));
  }

  void _startChoice(Map<String, dynamic> pending, List<FoodChoice> choices) {
    final entry = LogEntry.fromJson(pending);
    final items = entry is FoodEntry ? entry.items.length : -1;
    if (entry == null || entry.kind != kind || choices.any((c) => c.itemIndex >= items)) {
      _log('log: bad_envelope kind=${kind.wire}');
      return _set(CaptureMessage(CaptureText.forCode('bad_field', kind)));
    }
    _log('log: needs_choice kind=${kind.wire} n=${choices.length}');
    _set(CaptureChoice(entry, choices, checkedAgainst: checkedAgainstOf(pending)));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
