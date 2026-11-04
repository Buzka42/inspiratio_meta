/// Where long-term memory lives, chosen by voice: once after the interview
/// ("on this phone, or with your assistant?") and any time later with "use
/// my assistant for memory" or "keep memory on the phone". The phone is the
/// default. The VPS brain is named but refused until it exists. With
/// [MemoryModeSetup.typed] (voice off) the same question is answered by
/// typing and its prompts say "type" instead of "say".
///
/// Stored as one JSON string under [StoreKeys.memoryMode]. Logs carry codes
/// only, never a transcript.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';
import '../voice/setup_answers.dart' show normaliseAnswer;
import 'memory_backend.dart';
import 'memory_note.dart';

enum MemoryMode { phone, assistant, vps }

/// The saved choice. [chosen] is false until the user has answered, so the
/// question is asked once.
class MemoryModeChoice {
  const MemoryModeChoice({this.mode = MemoryMode.phone, this.chosen = false});
  final MemoryMode mode;
  final bool chosen;

  String encode() => jsonEncode({'mode': mode.name, 'chosen': chosen});

  /// The default (phone, not chosen) for null or malformed input. A stored
  /// `vps` falls back to the phone, since that backend refuses every call.
  static MemoryModeChoice decode(String? raw) {
    if (raw == null) return const MemoryModeChoice();
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return const MemoryModeChoice();
    }
    if (j is! Map) return const MemoryModeChoice();
    final m = MemoryMode.values.asNameMap()[j['mode']];
    return MemoryModeChoice(
        mode: m == null || m == MemoryMode.vps ? MemoryMode.phone : m, chosen: j['chosen'] == true);
  }
}

/// A [MemoryBackend] that forwards to the backend of the current [mode], so
/// the writer and the recall path follow a change at once.
class SelectedMemoryBackend implements MemoryBackend {
  SelectedMemoryBackend({
    required this.phone,
    required this.assistant,
    this.vps = const VpsMemoryBackend(),
    this.mode = MemoryMode.phone,
  });

  final MemoryBackend phone;
  final MemoryBackend assistant;
  final MemoryBackend vps;
  MemoryMode mode;

  MemoryBackend get current => switch (mode) {
        MemoryMode.phone => phone,
        MemoryMode.assistant => assistant,
        MemoryMode.vps => vps,
      };

  @override
  String get id => current.id;
  @override
  Future<void> write(MemoryNote note) => current.write(note);
  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) =>
      current.recall(query, k: k);
  @override
  Future<MemorySummary> summary() => current.summary();
}

// ---- Parsing ----------------------------------------------------------------

const _modeVerbs = {'use', 'keep', 'store', 'save', 'move', 'switch', 'put', 'set', 'change', 'hold'};
const _memoryWords = {'memory', 'memories'};
const _assistantWords = {'assistant', 'hermes', 'bot'};
const _phoneWords = {'phone', 'device', 'locally', 'local', 'here', 'telephone'};
const _vpsWords = {'server', 'vps', 'brain', 'cloud'};
const _questionStarts = {'what', 'why', 'how', 'where', 'who', 'which', 'do', 'does', 'is', 'are', 'can', 'could'};

MemoryMode? _target(Set<String> w) {
  final a = w.any(_assistantWords.contains), p = w.any(_phoneWords.contains), v = w.any(_vpsWords.contains);
  if ([a, p, v].where((x) => x).length != 1) return null;
  return a ? MemoryMode.assistant : (p ? MemoryMode.phone : MemoryMode.vps);
}

/// "use my assistant for memory", "keep memory on the phone", "store my
/// memories on my server": the mode named, or null. Questions and text that
/// names no memory word, no verb, or more than one place are null.
MemoryMode? parseMemoryModeIntent(String raw) {
  if (raw.trim().endsWith('?')) return null;
  final words = normaliseAnswer(raw).split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty || _questionStarts.contains(words.first)) return null;
  final w = words.toSet();
  if (!w.any(_memoryWords.contains) || !w.any(_modeVerbs.contains)) return null;
  return _target(w);
}

/// The answer to the memory question: a place word alone is enough ("the
/// phone", "my assistant"). Null when unreadable.
MemoryMode? parseMemoryModeAnswer(String raw) =>
    _target(normaliseAnswer(raw).split(' ').where((w) => w.isNotEmpty).toSet());

// ---- Prompts ----------------------------------------------------------------

abstract final class MemoryModePrompt {
  static const offer = 'Where should I keep long-term memory: on this phone, or with your assistant? '
      'Say phone or assistant.';
  static const reask = 'Please say phone or assistant.';
  static const phone = 'I will keep long-term memory on this phone.';
  static const assistant = 'I will keep long-term memory with your assistant.';
  static const noAssistant = 'No assistant is connected yet, so I will keep memory on this phone.';
  static const vps = 'Memory on your own server is not available yet. I will keep it on this phone.';
}

/// Typed prompts (voice off); the replies after a choice are shared.
abstract final class TypedMemoryModePrompt {
  static const offer = 'Where should I keep long-term memory: on this phone, or with your assistant? '
      'Type phone or assistant.';
  static const reask = 'Please type phone or assistant.';
}

// ---- Setup step -------------------------------------------------------------

class MemoryModeSetup {
  MemoryModeSetup({
    required this.store,
    required this.backend,
    required this.speak,
    this.listen,
    bool Function()? ready,
    bool Function()? assistantAvailable,
    this.typed = false,
    void Function(String line)? log,
  })  : _ready = ready ?? (() => true),
        _assistantAvailable = assistantAvailable ?? (() => true),
        _log = log ?? debugPrint;

  final StateStore store;

  /// Switched to the chosen mode.
  final SelectedMemoryBackend backend;
  final Future<void> Function(String text) speak;
  final void Function()? listen;

  /// False while earlier setup still runs; nothing is offered or claimed.
  final bool Function() _ready;

  /// False when no assistant link is configured (offline build).
  final bool Function() _assistantAvailable;

  /// Typed wording (voice off): see the library comment.
  final bool typed;
  final void Function(String) _log;

  MemoryModeChoice _choice = const MemoryModeChoice();
  bool _asking = false;
  Future<void> _queue = Future.value();

  MemoryMode get mode => _choice.mode;
  bool get chosen => _choice.chosen;
  bool get asking => _asking;
  Future<void> get settled => _queue;

  Future<void> load() async {
    _choice = MemoryModeChoice.decode(await store.getString(StoreKeys.memoryMode));
    backend.mode = _choice.mode;
  }

  /// Asks once, when ready and not yet answered.
  Future<void> offer() {
    _queue = _queue.then((_) async {
      if (_asking || _choice.chosen || !_ready()) return;
      _asking = true;
      await _ask(typed ? TypedMemoryModePrompt.offer : MemoryModePrompt.offer);
    });
    return _queue;
  }

  /// Takes every transcript while [asking], otherwise only a memory intent.
  bool claim(String text) {
    if (!_ready()) return false;
    final intent = parseMemoryModeIntent(text);
    if (!_asking && intent == null) return false;
    _queue = _queue.then((_) => _guarded(text, intent));
    return true;
  }

  Future<void> _guarded(String text, MemoryMode? intent) async {
    try {
      final m = intent ?? parseMemoryModeAnswer(text);
      if (m == null) {
        _log('setup: reask step=memory_mode');
        return await _ask(typed ? TypedMemoryModePrompt.reask : MemoryModePrompt.reask);
      }
      await choose(m);
    } catch (e) {
      _log('setup: memory_mode_failed error=${e.runtimeType}');
    }
  }

  /// Saves [m] (falling back to the phone when it cannot be used) and says
  /// where memory now lives.
  Future<void> choose(MemoryMode m) async {
    _asking = false;
    var said = switch (m) {
      MemoryMode.phone => MemoryModePrompt.phone,
      MemoryMode.assistant => MemoryModePrompt.assistant,
      MemoryMode.vps => MemoryModePrompt.vps,
    };
    var mode = m;
    if (m == MemoryMode.vps) mode = MemoryMode.phone;
    if (m == MemoryMode.assistant && !_assistantAvailable()) {
      mode = MemoryMode.phone;
      said = MemoryModePrompt.noAssistant;
    }
    _choice = MemoryModeChoice(mode: mode, chosen: true);
    backend.mode = mode;
    await store.setString(StoreKeys.memoryMode, _choice.encode());
    _log('setup: memory_mode=${mode.name}');
    await speak(said);
  }

  Future<void> _ask(String text) async {
    await speak(text);
    if (_asking) listen?.call();
  }
}
