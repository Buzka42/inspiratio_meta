/// The typed chat thread (PLAN.md decision 2026-10-28, build plan B2).
///
/// A list of entries `{role, text, sources?, offer?, trace?}` kept in the private
/// store under [StoreKeys.chatThread]. Consecutive assistant sentences merge
/// into one bubble; sources, traces and offers close a bubble. Entries hold the
/// user's own words, so they are never logged.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../voice/voice_session.dart';
import 'app_controller.dart';
import 'persistence.dart';

enum ChatRole { user, assistant }

/// An offer bubble's state. Only [open] offers take a tap.
enum OfferState { open, accepted, declined, closed }

class ChatOffer {
  const ChatOffer(this.id, [this.state = OfferState.open, this.choices]);
  final String id;
  final OfferState state;

  /// The answers shown as actions, in order (a food mismatch: "Keep mine
  /// (400)", "Use 270"); the last is the primary one. Null is Yes / No.
  /// A tap submits the label as typed text, like Yes and No.
  final List<String>? choices;

  bool get isOpen => state == OfferState.open;

  ChatOffer withState(OfferState s) => ChatOffer(id, s, choices);
}

@immutable
class ChatEntry {
  const ChatEntry({required this.role, required this.text, this.sources, this.offer, this.trace});
  final ChatRole role;
  final String text;

  /// "Sources: A · B" after a council answer.
  final String? sources;

  /// Set on a yes/no question ("Open your logs?").
  final ChatOffer? offer;

  /// The council trace lines after a council answer (council_flow.dart
  /// councilTraceLines).
  final List<String>? trace;

  ChatEntry copyWith({String? text, String? sources, ChatOffer? offer, List<String>? trace}) => ChatEntry(
      role: role,
      text: text ?? this.text,
      sources: sources ?? this.sources,
      offer: offer ?? this.offer,
      trace: trace ?? this.trace);

  Map<String, Object> toJson() => {
        'role': role.name,
        'text': text,
        'sources': ?sources,
        if (offer != null) 'offer': {'id': offer!.id, 'state': offer!.state.name, 'choices': ?offer!.choices},
        'trace': ?trace,
      };

  /// Null for anything malformed. An offer that was still open is closed:
  /// no offer survives a restart.
  static ChatEntry? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final role = ChatRole.values.asNameMap()[j['role']];
    final text = j['text'];
    if (role == null || text is! String) return null;
    final s = j['sources'];
    final o = j['offer'];
    ChatOffer? offer;
    if (o is Map<String, dynamic> && o['id'] is String) {
      final st = OfferState.values.asNameMap()[o['state']] ?? OfferState.closed;
      final ch = o['choices'];
      final choices = ch is List ? ch.whereType<String>().toList() : null;
      offer = ChatOffer(o['id'] as String, st == OfferState.open ? OfferState.closed : st,
          choices == null || choices.isEmpty ? null : List.unmodifiable(choices));
    }
    final tr = j['trace'];
    final trace = tr is List ? tr.whereType<String>().toList() : null;
    return ChatEntry(
        role: role,
        text: text,
        sources: s is String ? s : null,
        offer: offer,
        trace: trace == null || trace.isEmpty ? null : trace);
  }
}

class ChatThread extends ChangeNotifier {
  ChatThread({this.store, this.maxEntries = 200});

  final StateStore? store;

  /// Oldest entries are dropped past this many.
  final int maxEntries;

  final _entries = <ChatEntry>[];
  Future<void> _writes = Future.value();

  /// Whether the council trace panel is open. It starts open (owner
  /// decision 2026-10-30: the trace shows by default) and a tap's choice
  /// holds for later answers in this run.
  bool get traceOpen => _traceOpen;
  bool _traceOpen = true;

  void toggleTrace() {
    _traceOpen = !_traceOpen;
    notifyListeners();
  }

  List<ChatEntry> get entries => List.unmodifiable(_entries);

  /// The last user entry and everything after it (the latest exchange), or
  /// the trailing assistant entries when the user has not typed yet.
  List<ChatEntry> get latestExchange {
    final i = _entries.lastIndexWhere((e) => e.role == ChatRole.user);
    if (i >= 0) return List.unmodifiable(_entries.sublist(i));
    return List.unmodifiable(_entries.length <= 2 ? _entries : _entries.sublist(_entries.length - 2));
  }

  /// Completes when every write so far has finished.
  Future<void> get saved => _writes;

  Future<void> load() async {
    final raw = await store?.getString(StoreKeys.chatThread);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw);
      if (j is! List) return;
      _entries
        ..clear()
        ..addAll(j.map(ChatEntry.fromJson).whereType<ChatEntry>());
    } on FormatException {
      return;
    }
    notifyListeners();
  }

  /// A typed message. Any offer still open is closed (a new turn cancels it;
  /// the flow that owns the offer may then mark it accepted or declined).
  void addUser(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    for (var i = 0; i < _entries.length; i++) {
      final o = _entries[i].offer;
      if (o != null && o.isOpen) _entries[i] = _entries[i].copyWith(offer: o.withState(OfferState.closed));
    }
    _add(ChatEntry(role: ChatRole.user, text: t));
  }

  /// One assistant sentence; merged into the last bubble when that is an
  /// assistant bubble without sources or an offer, unless [alone].
  void addAssistant(String sentence, {bool alone = false}) {
    final t = sentence.trim();
    if (t.isEmpty) return;
    final last = _entries.isEmpty ? null : _entries.last;
    if (!alone &&
        last != null &&
        last.role == ChatRole.assistant &&
        last.sources == null &&
        last.offer == null &&
        last.trace == null) {
      _entries[_entries.length - 1] = last.copyWith(text: '${last.text} $t');
      _changed();
      return;
    }
    _add(ChatEntry(role: ChatRole.assistant, text: t));
  }

  /// True when the last entry is an assistant bubble ending with [text] (a
  /// prompt restored with the thread after a restart).
  bool endsWithAssistant(String text) {
    final t = text.trim();
    if (t.isEmpty || _entries.isEmpty) return false;
    final last = _entries.last;
    return last.role == ChatRole.assistant && last.offer == null && last.text.endsWith(t);
  }

  /// A yes/no question in its own bubble; [choices] replaces Yes / No with
  /// those answers.
  void addOffer(String text, String offerId, {List<String>? choices}) => _add(ChatEntry(
      role: ChatRole.assistant,
      text: text.trim(),
      offer: ChatOffer(offerId, OfferState.open, choices == null ? null : List.unmodifiable(choices))));

  /// Sets the state of offer [offerId]. No-op when it is not in the thread.
  void closeOffer(String offerId, OfferState state) {
    final i = _entries.lastIndexWhere((e) => e.offer?.id == offerId);
    if (i < 0 || _entries[i].offer!.state == state) return;
    _entries[i] = _entries[i].copyWith(offer: _entries[i].offer!.withState(state));
    _changed();
  }

  /// Attaches council sources to the last assistant bubble (or adds one).
  void attachSources(String sources) {
    final i = _entries.lastIndexWhere((e) => e.role == ChatRole.assistant);
    if (i < 0 || _entries[i].offer != null) {
      _add(ChatEntry(role: ChatRole.assistant, text: '', sources: sources));
      return;
    }
    _entries[i] = _entries[i].copyWith(sources: sources);
    _changed();
  }

  /// Attaches the council trace lines to the last assistant bubble (or adds
  /// one), like [attachSources].
  void attachTrace(List<String> lines) {
    if (lines.isEmpty) return;
    final i = _entries.lastIndexWhere((e) => e.role == ChatRole.assistant);
    if (i < 0 || _entries[i].offer != null) {
      _add(ChatEntry(role: ChatRole.assistant, text: '', trace: List.unmodifiable(lines)));
      return;
    }
    _entries[i] = _entries[i].copyWith(trace: List.unmodifiable(lines));
    _changed();
  }

  void _add(ChatEntry e) {
    _entries.add(e);
    if (_entries.length > maxEntries) _entries.removeRange(0, _entries.length - maxEntries);
    _changed();
  }

  void _changed() {
    notifyListeners();
    final s = store;
    if (s == null) return;
    final raw = jsonEncode([for (final e in _entries) e.toJson()]);
    _writes = _writes.then((_) => s.setString(StoreKeys.chatThread, raw));
  }
}

/// A typed turn: the text goes into [thread] as the user's bubble, then
/// through the voice reducer ([TextSubmitted]) into
/// AppController.handleUtterance, setupHook and routeTurn unchanged.
void submitTypedTurn(AppController controller, ChatThread thread, String text) {
  final t = text.trim();
  if (t.isEmpty) return;
  thread.addUser(t);
  controller.dispatch(TextSubmitted(t));
}
