/// Items the assistant pushes to Illunis (GET /assistant/inbox,
/// docs/DESIGN.md). Polled when the app comes to
/// the foreground and after the wake word, only while long-term memory is
/// with the assistant. The server marks items read when it hands them out,
/// so they are kept on the phone (private store) until spoken.
///
/// Items are spoken one at a time, oldest first, at the next natural pause:
/// only when [AssistantInbox.quiet] holds (no turn, no listening, no speech,
/// no open question) for [AssistantInbox.pauseDelay]. One the user
/// interrupts goes back to the front. At the morning digest they are folded
/// in after the digest instead.
///
/// Logs carry counts and codes only, never item text.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'aside.dart';
import 'persistence.dart';
import 'server_port.dart';

/// Kept at most; the oldest are dropped past it.
const inboxKeep = 50;

/// What Illunis says before an item, by kind.
String inboxLine(InboxItem i) => switch (i.kind) {
      'reminder' => 'A reminder from your assistant: ${i.text}',
      'bot_reply' => 'A reply came in through your assistant: ${i.text}',
      'action_result' => 'An update from your assistant: ${i.text}',
      'memory' => 'Your assistant noted: ${i.text}',
      _ => 'A message from your assistant: ${i.text}',
    };

/// [queued] plus [fresh] without repeats, ordered by ts (arrival order on a
/// tie), capped at [inboxKeep] newest.
List<InboxItem> mergeInbox(List<InboxItem> queued, List<InboxItem> fresh) {
  final seen = <String>{};
  final all = <(int, InboxItem)>[];
  for (final i in [...queued, ...fresh]) {
    if (seen.add(i.id)) all.add((all.length, i));
  }
  all.sort((a, b) {
    final t = a.$2.ts.compareTo(b.$2.ts);
    return t != 0 ? t : a.$1.compareTo(b.$1);
  });
  final out = [for (final e in all) e.$2];
  return out.length <= inboxKeep ? out : out.sublist(out.length - inboxKeep);
}

class AssistantInbox {
  AssistantInbox({
    required this.server,
    required this.store,
    required this.speak,
    required this.quiet,
    required this.enabled,
    OneShotTimer? timer,
    DateTime Function()? clock,
    this.minPollGap = const Duration(seconds: 30),
    this.pauseDelay = const Duration(seconds: 2),
    this.maxPages = 3,
    this.onSpecRequest,
    AsideLog? log,
  })  : _timer = timer ?? realTimer,
        _clock = clock ?? DateTime.now,
        _log = log ?? debugPrint;

  final ServerPort server;
  final StateStore store;
  final AsideSpeak speak;

  /// True at a natural pause (nothing said, heard or asked).
  final bool Function() quiet;

  /// True while memory mode is the assistant and an assistant is linked.
  final bool Function() enabled;
  final Duration minPollGap;
  final Duration pauseDelay;
  final int maxPages;

  /// Gets the user's words of each `spec_request` (the bot relayed a change
  /// request); they become a chat card, not a spoken item.
  final void Function(String words)? onSpecRequest;
  final OneShotTimer _timer;
  final DateTime Function() _clock;
  final AsideLog _log;

  List<InboxItem> _items = [];
  DateTime? _lastPoll;
  bool _polling = false, _speaking = false;
  Timer? _pause;

  List<InboxItem> get pending => List.unmodifiable(_items);

  Future<void> load() async {
    final raw = await store.getString(StoreKeys.assistantInbox);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw);
      final list = j is Map ? j['items'] : null;
      _items = mergeInbox(const [], [for (final i in (list is List ? list : const [])) ?InboxItem.fromJson(i)]);
    } on FormatException {
      _items = [];
    }
  }

  Future<void> _save() =>
      store.setString(StoreKeys.assistantInbox, jsonEncode({'v': 1, 'items': [for (final i in _items) i.toJson()]}));

  /// Fetches new items (at most [maxPages] pages while the server says
  /// `more`). Skipped while disabled, while a poll runs, and within
  /// [minPollGap] of the last one unless [force].
  Future<void> poll({bool force = false}) async {
    if (!enabled() || _polling) return;
    final now = _clock();
    final last = _lastPoll;
    if (!force && last != null && now.difference(last) < minPollGap) return;
    _polling = true;
    _lastPoll = now;
    try {
      final fresh = <InboxItem>[];
      for (var page = 0; page < maxPages; page++) {
        final b = await server.assistantInbox();
        fresh.addAll(b.items);
        if (!b.more) break;
      }
      if (onSpecRequest case final hand?) {
        for (final i in fresh.where((i) => i.kind == 'spec_request')) {
          hand(i.text);
        }
        fresh.removeWhere((i) => i.kind == 'spec_request');
      }
      if (fresh.isEmpty) return;
      _items = mergeInbox(_items, fresh);
      await _save();
      _log('inbox: received count=${fresh.length}');
    } catch (e) {
      _log('inbox: poll_failed code=${asideCode(e)}');
    } finally {
      _polling = false;
    }
    onPause();
  }

  /// Call whenever the app may have gone quiet (controller listener, end of
  /// a turn). Arms one check after [pauseDelay]; while items wait, the check
  /// re-arms until a pause comes.
  void onPause() {
    if (_items.isEmpty || _pause != null || _speaking) return;
    _pause = _timer(pauseDelay, () {
      _pause = null;
      unawaited(_deliver());
    });
  }

  Future<void> _deliver() async {
    if (_items.isEmpty || _speaking) return;
    if (!enabled()) return;
    if (!quiet()) return onPause();
    _speaking = true;
    var spoken = 0;
    try {
      while (_items.isNotEmpty && quiet()) {
        final item = _items.first;
        if (!await speak(inboxLine(item))) break; // Interrupted: it stays first.
        _items.remove(item);
        spoken++;
        await _save();
      }
    } finally {
      _speaking = false;
      if (spoken > 0) _log('inbox: spoken count=$spoken');
    }
    onPause();
  }

  /// Folds waiting items into the morning digest: speaks each with an
  /// "Also" lead-in. False when the user interrupted (the rest stay).
  Future<bool> speakForDigest() async {
    if (!enabled() || _items.isEmpty || _speaking) return true;
    _speaking = true;
    try {
      while (_items.isNotEmpty) {
        final item = _items.first;
        if (!await speak('Also: ${inboxLine(item)}')) return false;
        _items.remove(item);
        await _save();
      }
      _log('inbox: folded_into_digest');
      return true;
    } finally {
      _speaking = false;
    }
  }

  void dispose() {
    _pause?.cancel();
    _pause = null;
  }
}
