/// Settings through chat (PLAN-chat-settings.md). There is no settings menu:
/// [parseSpecIntent] is a fixed-phrase gate, and only a `change` asks the
/// Worker (POST /spec/propose with the user's words). The answer becomes one
/// offer card, `<readback> Approve this change?` with Cancel / Approve, and
/// only an exact "Approve" on an open, unexpired card calls specApply.
/// Read-only questions are answered from GET /spec with fixed sentences, no
/// model call. Logs carry fixed codes only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_thread.dart';
import 'persistence.dart';
import 'server_port.dart';
import 'settings_spec.dart';

enum SpecIntent { change, show, capabilities, addSource, removeSource, setup, link }

RegExp _re(String p) => RegExp(p, caseSensitive: false);
final _setup = _re(r'\bset ?up my assistant\b');
final _link = _re(r'\blink my (bot|assistant)\b');
final _add = _re(r'^add (a |the |my )?(reading )?source\b');
final _remove = _re(r'^(remove|delete) (a |the |my )?(reading )?source\b');
final _show = _re(r'\b(show|list|see|view|what are|tell me)\b.*\bsettings\b');
final _caps = _re(r'\bwhat can you do\b|\bwhat are your (skills|abilities)\b');
final _verb = _re(r'\b(turn|switch)\b.*\b(on|off)\b|\b(enable|disable|stop|start|use|keep|change|set)\b|\bno more\b');
final _noun = _re('\\b(${[
  ...skillIds,
  ...brains.where((b) => b != 'auto'),
  'hermes', 'memory', 'notifications?', 'morning note', 'retention', 'proactivity', 'check-?ins?', 'brain', 'sources?',
].join('|')})\\b');

/// The intent of [text], or null for anything that is not about settings.
SpecIntent? parseSpecIntent(String text) {
  final t = text.trim();
  final head = t.split('\n').first.trim();
  if (_setup.hasMatch(t)) return SpecIntent.setup;
  if (_link.hasMatch(t)) return SpecIntent.link;
  if (_add.hasMatch(head)) return SpecIntent.addSource;
  if (_remove.hasMatch(head)) return SpecIntent.removeSource;
  if (_show.hasMatch(t)) return SpecIntent.show;
  if (_caps.hasMatch(t)) return SpecIntent.capabilities;
  if (_verb.hasMatch(t) && _noun.hasMatch(t)) return SpecIntent.change;
  return null;
}

abstract final class SpecLine {
  static const ask = 'Approve this change?';
  static const cancelled = 'Cancelled. Nothing changed.';
  static const expired = 'That change expired. Ask again.';
  static const gone = 'That change is no longer waiting. Ask again.';
  static const stale = 'Your settings changed in the meantime. Ask again.';
  static const already = 'That is already how it is set.';
  static const typeIt = 'Type that yourself.';
  static const fixed = 'That safety line is fixed.';
  static const declined = 'Your assistant declined.';
  static const unreachable = 'I could not reach the server.';
  static const forbidden = "Only the owner's phone can change this.";
  static const couldNot = 'I could not make that change.';
  static const notUnderstood = 'I did not understand that change. Try: turn off breathwork';
  static const catchUp = 'Hermes will catch up.';
  static const fromAssistant = 'Your assistant asked for this change.';
  static const pasteIt = 'Paste the text. The first line is the title.';
  static const needBoth = "I need a title line and then the text. Say 'add a source' to try again.";
  static const tooLong = 'That is too long. A title fits 120 characters and the text 3200.';
  static const whichSource = 'Which source?';
  static const notReady = 'That is not ready yet.';
  static const inChat = 'I put the change in the chat.';
  static String changed(int v) => "Your settings changed (version $v). Say 'show my settings' to see them.";
}

const _misread = {'unknown_key', 'unknown_skill', 'bad_value', 'read_only'};

/// The sentence for a refusal list (`(path, reason)` reasons).
String refusedLine(Iterable<String> reasons) => reasons.contains('no_change')
    ? SpecLine.already
    : reasons.contains('app_only')
        ? SpecLine.typeIt
        : reasons.contains('guardrail')
            ? SpecLine.fixed
            : reasons.any(_misread.contains)
                ? SpecLine.notUnderstood
                : SpecLine.couldNot;

/// A server code safe to log: fixed-shape or `other`.
String logCode(String? c) => c != null && RegExp(r'^[a-z_]{1,32}$').hasMatch(c) ? c : 'other';

String _cap(String w) => '${w[0].toUpperCase()}${w.substring(1)}';

/// For a no-op change: the setting [words] name, said as it already is in
/// [s] ("Memory is already on the phone."); null when no setting is named.
String? alreadyLine(String words, SettingsSpec s) {
  final t = words.toLowerCase();
  bool has(String p) => RegExp('\\b($p)\\b').hasMatch(t);
  for (final k in skillIds) {
    if (has(k)) return '${_cap(k)} is already ${s.skills[k] == true ? 'on' : 'off'}.';
  }
  if (has(r'\d+ ?days?|retention')) return 'Memory is already kept for ${s.retentionDays} days.';
  if (has('memory')) {
    return switch (s.memoryMode) {
      'off' => 'Memory is already off.',
      'hermes' => 'Memory is already kept in Hermes.',
      _ => 'Memory is already on the phone.',
    };
  }
  if (has(['brain', ...brains].join('|'))) return 'The brain is already ${s.brain}.';
  return null;
}

/// The sentence for a fixed server code.
String serverLine(String code) => switch (code) {
      'no_change' => SpecLine.already,
      'not_understood' => SpecLine.notUnderstood,
      'agent_refused' => SpecLine.declined,
      'unavailable' || 'spec_unavailable' || 'not_configured' => SpecLine.unreachable,
      'spec_forbidden' => SpecLine.forbidden,
      'stale_version' => SpecLine.stale,
      'change_expired' => SpecLine.expired,
      'change_unknown' => SpecLine.gone,
      _ => SpecLine.couldNot,
    };

const _proactivity = {
  'never': 'I only speak when you do.',
  'daily': 'I check in once a day.',
  'events': 'I check in when something happens.',
};

List<String> _skills(SettingsSpec s, bool on) => [for (final k in skillIds) if (s.skills[k] == on) k];

/// "show my settings": fixed sentences built from [st] and [sources].
String describeSpec(SpecState st, [List<KnowledgeSource> sources = const []]) {
  final s = st.spec, on = _skills(s, true), off = _skills(s, false);
  return [
    on.isEmpty ? 'No skills are on.' : 'Skills on: ${on.join(', ')}.',
    if (off.isNotEmpty) 'Skills off: ${off.join(', ')}.',
    switch (s.memoryMode) {
      'off' => 'Memory is off.',
      'hermes' => 'Memory is kept in Hermes for ${s.retentionDays} days.',
      _ => 'Memory stays on this phone for ${s.retentionDays} days.',
    },
    _proactivity[s.proactivity] ?? '',
    'Brain: ${s.brain}.',
    if (st.guardrails.isNotEmpty) 'Fixed safety lines: ${st.guardrails.join(' ')}',
    sources.isEmpty ? 'No reading sources.' : 'Sources: ${sources.map((x) => x.title).join(', ')}.',
    'Settings version ${s.version}.',
  ].where((l) => l.isNotEmpty).join(' ');
}

/// "what can you do": fixed sentences built from [s].
String describeCapabilities(SettingsSpec s) {
  final on = _skills(s, true);
  return [
    on.isEmpty ? 'No skills are on right now.' : 'I can help with ${on.join(', ')}.',
    'In this chat you can turn a skill on or off, choose where memory is kept and for how long, '
        'set how often I check in, pick the brain, and add or remove a reading source.',
    "Say 'show my settings' to see them.",
  ].join(' ');
}

/// On app open: when GET /spec gives a version other than the stored one,
/// adds [SpecLine.changed] (the server's number) as its own message after
/// the last one, once per version. The first read only stores it. A failed
/// read says nothing.
Future<void> noteSpecVersion(ServerPort server, StateStore store, ChatThread thread) async {
  try {
    final v = (await server.specGet()).spec.version;
    final seen = int.tryParse(await store.getString(StoreKeys.specVersion) ?? '');
    if (seen == v) return;
    await store.setString(StoreKeys.specVersion, '$v');
    final line = SpecLine.changed(v);
    if (seen != null && !thread.endsWithAssistant(line)) thread.addAssistant(line, alone: true);
  } catch (e) {
    debugPrint('spec: version_check_failed error=${e.runtimeType}');
  }
}

typedef SpecTimer = Timer Function(Duration d, void Function() f);
Timer _realTimer(Duration d, void Function() f) => Timer(d, f);

class _Card {
  _Card(this.offerId, this.proposal, this.expiresAt);
  final String offerId;
  final SpecProposal proposal;
  final DateTime expiresAt;
  Timer? timer;
}

class SpecChatFlow {
  SpecChatFlow({
    required this.server,
    required this.thread,
    this.redispatch,
    this.onSetup,
    this.onLink,
    DateTime Function()? clock,
    SpecTimer? timer,
    void Function(String line)? log,
  })  : _clock = clock ?? DateTime.now,
        _timer = timer ?? _realTimer,
        _log = log ?? debugPrint;

  final ServerPort server;
  final ChatThread thread;

  /// Sends [text] on as a normal turn (not_understood, crisis); the next
  /// claim of exactly that text is let through once.
  final void Function(String text)? redispatch;
  final VoidCallback? onSetup, onLink;

  /// Used when the Worker's answer has no `expires_at` (PENDING_TTL_MS).
  static const pendingTtl = Duration(minutes: 5);
  static const titleMax = 120, textMax = 3200;

  final DateTime Function() _clock;
  final SpecTimer _timer;
  final void Function(String) _log;

  _Card? _card;
  List<KnowledgeSource>? _picks;
  String? _pickId, _bypass;
  bool _awaitSource = false;
  int _seq = 0;
  Future<void> _queue = Future.value();

  Future<void> get settled => _queue;
  String? get openCardId => _card?.offerId;

  /// For AppController.setupHook, right after approval.claim. True when
  /// [text] was taken.
  bool claim(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (t == _bypass) {
      _bypass = null;
      return false;
    }
    final low = t.toLowerCase();
    if (_card case final card?) {
      if (low == 'approve') {
        if (!_clock().isBefore(card.expiresAt)) {
          _expire();
        } else {
          card.timer?.cancel();
          _card = null;
          _run(() => _approve(card));
        }
        return true;
      }
      _closeCard(OfferState.declined);
      _say(SpecLine.cancelled);
      if (low == 'cancel') return true;
    }
    if (_picks case final picks?) {
      _picks = null;
      final hit = picks.where((s) => s.title.toLowerCase() == low).firstOrNull;
      thread.closeOffer(_pickId!, hit == null ? OfferState.declined : OfferState.accepted);
      if (hit != null) return _run(() => _removeSource(hit));
      if (low == 'cancel') return _sayTaken(SpecLine.cancelled);
    }
    if (_awaitSource) {
      _awaitSource = false;
      if (low == 'cancel') return _sayTaken(SpecLine.cancelled);
      final lines = t.split('\n');
      return _addSource(lines.first.trim(), lines.skip(1).join('\n').trim());
    }
    switch (parseSpecIntent(t)) {
      case null:
        return false;
      case SpecIntent.change:
        return _run(() => _propose((b) => server.specPropose(baseVersion: b, request: t), words: t, said: t));
      case SpecIntent.show:
        return _run(() async {
          final st = await server.specGet();
          final src = await server.knowledgeSources().catchError((Object _) => const <KnowledgeSource>[]);
          _say(describeSpec(st, src));
        });
      case SpecIntent.capabilities:
        return _run(() async => _say(describeCapabilities((await server.specGet()).spec)));
      case SpecIntent.addSource:
        final lines = t.split('\n'), head = lines.first, colon = head.indexOf(':');
        final title = colon < 0 ? '' : head.substring(colon + 1).trim(), body = lines.skip(1).join('\n').trim();
        if (title.isEmpty || body.isEmpty) {
          _awaitSource = true;
          return _sayTaken(SpecLine.pasteIt);
        }
        return _addSource(title, body);
      case SpecIntent.removeSource:
        final q = t.split('\n').first.replaceFirst(_remove, '').trim();
        return _run(() => _findSource(q));
      case SpecIntent.setup:
        return _hand(onSetup);
      case SpecIntent.link:
        return _hand(onLink);
    }
  }

  /// A change the assistant asked for in [words] (inbox `spec_request`):
  /// the same card, led by [SpecLine.fromAssistant].
  Future<void> proposeFromWords(String words) {
    _closeCard(OfferState.closed);
    _run(() => _propose((b) => server.specPropose(baseVersion: b, request: words),
        lead: SpecLine.fromAssistant, said: words));
    return _queue;
  }

  bool _hand(VoidCallback? f) {
    if (f == null) return _sayTaken(SpecLine.notReady);
    f();
    return true;
  }

  bool _addSource(String title, String body) {
    if (title.isEmpty || body.isEmpty) return _sayTaken(SpecLine.needBoth);
    if (title.length > titleMax || body.length > textMax) return _sayTaken(SpecLine.tooLong);
    return _run(() => _propose((b) => server.knowledgeAdd(baseVersion: b, title: title, text: body),
        label: "Add '$title' (${body.length} characters)."));
  }

  Future<void> _findSource(String q) async {
    final all = await server.knowledgeSources();
    final hits = [for (final s in all) if (q.isEmpty || s.title.toLowerCase().contains(q.toLowerCase())) s];
    if (hits.isEmpty) return _say(q.isEmpty ? 'You have no sources.' : "I found no source called '$q'.");
    if (hits.length == 1) return _removeSource(hits.single);
    _picks = hits;
    _pickId = 'spec-pick:${++_seq}';
    thread.addOffer(SpecLine.whichSource, _pickId!, choices: [for (final s in hits) s.title, 'Cancel']);
  }

  Future<void> _removeSource(KnowledgeSource s) =>
      _propose((b) => server.knowledgeRemove(baseVersion: b, sourceId: s.id), label: "Remove '${s.title}'.");

  /// Proposes, then shows the card. [words] marks a request in words, whose
  /// not_understood or crisis answer goes on as a normal turn. [said] is the
  /// request a no-op answer names ("Memory is already on the phone.").
  Future<void> _propose(Future<SpecProposal> Function(int baseVersion) call,
      {String? label, String lead = '', String? words, String? said}) async {
    SettingsSpec? spec;
    void already() {
      final s = spec;
      _say((s == null ? null : alreadyLine(said ?? '', s)) ?? SpecLine.already);
    }

    try {
      final p = await call((spec = (await server.specGet()).spec).version);
      if (p.diff.isEmpty) {
        _log('spec: no_change');
        return already();
      }
      _openCard(p, label ?? p.readback, lead);
      _log('spec: card');
    } on SpecRefused catch (e) {
      final reasons = e.refused.map((r) => r.$2);
      _log('spec: refused reason=${logCode(reasons.firstOrNull)}');
      reasons.contains('no_change') ? already() : _say(refusedLine(reasons));
    } on ServerException catch (e) {
      final code = e.code ?? e.error;
      _log('spec: propose_failed code=${logCode(code)}');
      final send = redispatch;
      if (words != null && send != null && (code == 'not_understood' || code == 'crisis')) {
        _bypass = words;
        send(words);
        return;
      }
      code == 'no_change' ? already() : _say(serverLine(code));
    }
  }

  void _openCard(SpecProposal p, String label, String lead) {
    _closeCard(OfferState.closed);
    final exp = p.expiresAt ?? _clock().add(pendingTtl);
    final card = _card = _Card('spec:${p.changeId}', p, exp);
    thread.addOffer([lead, label, SpecLine.ask].where((s) => s.isNotEmpty).join(' '), card.offerId,
        choices: const ['Cancel', 'Approve']);
    final wait = exp.difference(_clock());
    card.timer = _timer(wait.isNegative ? Duration.zero : wait, () {
      if (identical(_card, card)) _expire();
    });
  }

  Future<void> _approve(_Card card) async {
    try {
      final st = await server.specApply(card.proposal.changeId);
      thread.closeOffer(card.offerId, OfferState.accepted);
      final rb = card.proposal.readback.isEmpty ? 'Changed.' : card.proposal.readback;
      _say(['Done: $rb', if (st.mirror == 'pending') SpecLine.catchUp].join(' '));
      _log('spec: applied');
    } on ServerException catch (e) {
      thread.closeOffer(card.offerId, OfferState.closed);
      _log('spec: apply_failed code=${e.code ?? e.error}');
      _say(serverLine(e.code ?? e.error));
    }
  }

  void _expire() {
    _log('spec: expired');
    _closeCard(OfferState.closed);
    _say(SpecLine.expired);
  }

  void _closeCard(OfferState state) {
    final c = _card;
    if (c == null) return;
    c.timer?.cancel();
    _card = null;
    thread.closeOffer(c.offerId, state);
  }

  void _say(String s) => thread.addAssistant(s);

  bool _sayTaken(String s) {
    _say(s);
    return true;
  }

  /// Queues [body]; an unexpected failure says [SpecLine.unreachable].
  bool _run(Future<void> Function() body) {
    _queue = _queue.then((_) async {
      try {
        await body();
      } catch (e) {
        _log('spec: failed error=${e.runtimeType}');
        _say(SpecLine.unreachable);
      }
    });
    return true;
  }
}
