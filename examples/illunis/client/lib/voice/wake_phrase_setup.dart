/// Voice setup for the 2 to 4 word wake phrase: asked once
/// after the interview, changed later with "change my wake phrase to hey
/// Vega". The phrase is normalised and validated by input/wake/wake_phrase.dart;
/// a rejected phrase gets a spoken retry naming the reason. The single-word
/// keyword from the interview stays as it is and remains the fallback: "none"
/// keeps only the word.
///
/// Storage follows the app's key-value pattern (one JSON string under
/// [wakePhraseKey]); the store functions are passed in so this library stays
/// free of app imports (main.dart passes the guarded StateStore's methods).
/// Logs carry codes only, never the phrase.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../input/wake/wake_phrase.dart';
import 'setup_answers.dart';
import 'setup_intent.dart';

const wakePhraseKey = 'wake_phrase';

/// What is stored: a phrase, an explicit "none", or nothing yet.
class StoredWakePhrase {
  const StoredWakePhrase({this.phrase, this.declined = false});
  final WakePhrase? phrase;

  /// The user said "none": keep the single word, do not ask again.
  final bool declined;

  /// True when the user has answered the question either way.
  bool get answered => phrase != null || declined;

  String encode() => jsonEncode(phrase != null ? {'phrase': phrase!.text} : {'declined': declined});

  /// Nothing for null, malformed or no longer valid input, so setup asks again.
  static StoredWakePhrase decode(String? raw) {
    if (raw == null) return const StoredWakePhrase();
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return const StoredWakePhrase();
    }
    if (j is! Map<String, dynamic>) return const StoredWakePhrase();
    final p = j['phrase'];
    if (p is String) return StoredWakePhrase(phrase: WakePhrase.tryCreate(p));
    return StoredWakePhrase(declined: j['declined'] == true);
  }
}

class WakePhraseStore {
  const WakePhraseStore({required this.read, required this.write});

  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;

  Future<StoredWakePhrase> load() async => StoredWakePhrase.decode(await read(wakePhraseKey));

  Future<void> save(StoredWakePhrase s) => write(wakePhraseKey, s.encode());
}

// ---- Parsing ----------------------------------------------------------------

sealed class WakePhraseAnswer {
  const WakePhraseAnswer();
}

/// "none": keep the single word only.
class DeclinePhrase extends WakePhraseAnswer {
  const DeclinePhrase();
}

/// The spoken phrase, not yet validated.
class PhraseText extends WakePhraseAnswer {
  const PhraseText(this.text);
  final String text;
}

const _phraseLeads = [
  'my wake phrase is ',
  'the wake phrase is ',
  'my phrase is ',
  'the phrase is ',
  "let's use ",
  'lets use ',
  'how about ',
  'use ',
];

const _declines = {
  'none', 'no', 'nope', 'skip', 'no thanks', 'no thank you', 'none thanks', 'none please',
  'none thank you', 'keep the word', 'keep my word', 'keep my wake word', 'just the word',
};

/// The answer to the phrase question, or null when nothing was said.
WakePhraseAnswer? parseWakePhraseAnswer(String raw) {
  var t = normaliseAnswer(raw);
  if (_declines.contains(t)) return const DeclinePhrase();
  for (final lead in _phraseLeads) {
    if (t.startsWith(lead)) {
      t = t.substring(lead.length);
      break;
    }
  }
  if (t.endsWith(' please')) t = t.substring(0, t.length - ' please'.length);
  return t.isEmpty ? null : PhraseText(t);
}

final _phraseIntent = RegExp(
    r'^(?:change|set|update|make|switch|reset) (?:my |the )?wake ?(?:up )?phrase(?: (?:to|is|as) (.+))?$');

/// "change my wake phrase [to hey vega]": a record whose value is the spoken
/// phrase, or null when only the target was named. Null for text that is not
/// this intent.
({String? value})? parseWakePhraseIntent(String raw) {
  var t = normaliseAnswer(raw);
  for (final lead in const ['please ', 'can you ', 'could you ', 'i want to ', "i'd like to "]) {
    if (t.startsWith(lead)) t = t.substring(lead.length);
  }
  if (t.endsWith(' please')) t = t.substring(0, t.length - ' please'.length);
  final m = _phraseIntent.firstMatch(t);
  return m == null ? null : (value: m[1]);
}

// ---- Prompts ----------------------------------------------------------------

abstract final class WakePhrasePrompt {
  static const offer = 'You can also wake me with a short phrase of two to four words, '
      'such as hey Vega. Say your phrase, or say none to keep your wake word.';
  static const edit = 'Say your new wake phrase, two to four words, such as hey Vega.';
  static const reask = 'Please say a phrase of two to four words, or say none.';
  static const declined = 'All right. I will listen for your wake word.';
  static String accepted(WakePhrase p) => 'Your wake phrase is now ${p.text}.';

  static String rejected(WakePhraseRejection r) => switch (r) {
        WakePhraseRejection.empty => reask,
        WakePhraseRejection.tooFewWords =>
          'That is only one word. Please say two to four words, such as hey Vega.',
        WakePhraseRejection.tooManyWords => 'That is too long. Please say no more than four words.',
        WakePhraseRejection.tooLong => 'That phrase is too long. Please choose shorter words.',
        WakePhraseRejection.unsupportedCharacters => 'Please use only plain words, without numbers.',
        WakePhraseRejection.commonWords => 'Those words are too common and would wake me by accident. '
            'Please add an unusual word, like the name of a star.',
        WakePhraseRejection.bareGreeting => 'A greeting alone would wake me by accident. '
            'Please add an unusual word, such as hey Vega.',
      };
}

// ---- Setup step -------------------------------------------------------------

class WakePhraseSetup {
  WakePhraseSetup({
    required this.store,
    required this.speak,
    this.listen,
    this.onPhraseChanged,
    bool Function()? ready,
    void Function(String line)? log,
  })  : _ready = ready ?? (() => true),
        _log = log ?? debugPrint;

  final WakePhraseStore store;

  /// Speaks a prompt (the app passes the interview's TtsPort.speak).
  final Future<void> Function(String text) speak;

  /// Opens a listening session after a prompt that expects an answer.
  final void Function()? listen;

  /// Called after the phrase is set, changed or declined (the input
  /// pipeline's refreshKeyword, so the wake port is chosen again).
  final void Function()? onPhraseChanged;

  /// False while the interview runs; the phrase is neither offered nor
  /// edited until it is done.
  final bool Function() _ready;
  final void Function(String line) _log;

  StoredWakePhrase _stored = const StoredWakePhrase();
  bool _asking = false;
  Future<void> _queue = Future.value();

  WakePhrase? get phrase => _stored.phrase;
  bool get declined => _stored.declined;

  /// True while a phrase answer is expected.
  bool get asking => _asking;

  /// Completes when every claimed transcript has been handled.
  Future<void> get settled => _queue;

  Future<void> load() async => _stored = await store.load();

  /// Asks for the phrase once the interview is done, unless it was already
  /// answered or is being asked.
  Future<void> offer() {
    _queue = _queue.then((_) async {
      if (_asking || _stored.answered || !_ready()) return;
      _asking = true;
      await _ask(WakePhrasePrompt.offer);
    });
    return _queue;
  }

  /// For the app's setup hook: takes every transcript while [asking]
  /// (except another setup change, which is released to VoiceSetup), and
  /// otherwise only "change my wake phrase".
  bool claim(String text) {
    if (!_ready()) return false;
    final intent = parseWakePhraseIntent(text);
    if (!_asking && intent == null) return false;
    if (_asking && intent == null && parseSetupIntent(text) != null) {
      _asking = false;
      return false;
    }
    _queue = _queue.then((_) => _guarded(text));
    return true;
  }

  /// Handles one transcript now. Prefer [claim] in the app.
  Future<void> hear(String text) => _guarded(text);

  Future<void> _guarded(String text) async {
    try {
      await _handle(text);
    } catch (e) {
      _log('setup: wake_phrase_failed error=${e.runtimeType}');
    }
  }

  Future<void> _handle(String text) async {
    final intent = parseWakePhraseIntent(text);
    if (intent != null) {
      _asking = true;
      final v = intent.value;
      if (v == null) return _ask(WakePhrasePrompt.edit);
      return _answer(v);
    }
    if (_asking) return _answer(text);
  }

  Future<void> _answer(String text) async {
    switch (parseWakePhraseAnswer(text)) {
      case null:
        _log('setup: reask step=wake_phrase');
        return _ask(WakePhrasePrompt.reask);
      case DeclinePhrase():
        await _save(const StoredWakePhrase(declined: true));
        _log('setup: wake_phrase_declined');
        return speak(WakePhrasePrompt.declined);
      case PhraseText(:final text):
        final rejection = validateWakePhrase(text);
        if (rejection != null) {
          _log('setup: wake_phrase_rejected code=${rejection.name}');
          return _ask(WakePhrasePrompt.rejected(rejection));
        }
        final p = WakePhrase.tryCreate(text)!;
        await _save(StoredWakePhrase(phrase: p));
        _log('setup: wake_phrase_saved');
        return speak(WakePhrasePrompt.accepted(p));
    }
  }

  Future<void> _save(StoredWakePhrase s) async {
    _asking = false;
    _stored = s;
    await store.save(s);
    onPhraseChanged?.call();
  }

  Future<void> _ask(String text) async {
    await speak(text);
    if (_asking) listen?.call();
  }
}
