/// The expert council in conversation (docs/DESIGN.md
/// section 3). After a normal reply to a big question (council_trigger.dart
/// rules, or the reply model's `council_suggested` flag) Illunis asks "Want
/// me to ask the council?" and listens. A yes, or an explicit "ask the
/// council about ...", sends the question to POST /council (purpose chat)
/// with the short-term context. The synthesis is spoken through the shared
/// speech queue, the medical line with it, and the source titles show
/// briefly as a caption. In typed chat the server's trace (which experts,
/// which sources, whether web search ran) shows under the answer
/// ([councilTraceLines]).
///
/// Logs carry fixed codes only, never a question or an answer.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../memory/short_term_memory.dart';
import '../voice/confirm_phrase.dart';
import '../voice/council_trigger.dart';
import 'app_controller.dart';
import 'aside.dart';
import 'server_port.dart';
import 'view_offer.dart';

/// The server's NOT_MEDICAL_ADVICE (server/src/safety.js). The Worker
/// appends it to every medical synthesis; the phone adds it again only if a
/// medical answer arrives without it.
const notMedicalAdviceLine = 'This is not medical advice. Talk to a clinician about any health concern.';

abstract final class CouncilPrompt {
  static const offer = 'Want me to ask the council?';
  static const asking = 'I will ask the council. This can take a little while.';
  static const declined = 'All right.';
  static const unavailable = 'The council is not available right now.';
  static const needQuestion = 'What should I ask the council? For example: ask the council why I wake up at night.';
}

/// The synthesis with the medical line ensured when [medical].
String withMedicalLine(String synthesis, bool medical) =>
    !medical || synthesis.contains(notMedicalAdviceLine) ? synthesis : '$synthesis $notMedicalAdviceLine';

/// "Sources: A · B · C", at most [max] titles of at most 60 characters (a
/// longer title ends in one ellipsis character), or null when there are
/// none.
String? sourcesCaption(List<CouncilSource> sources, {int max = 3}) {
  final titles = <String>[];
  for (final s in sources) {
    final t = s.title.length <= 60 ? s.title : '${s.title.substring(0, 59).trimRight()}…';
    if (!titles.contains(t)) titles.add(t);
    if (titles.length == max) break;
  }
  return titles.isEmpty ? null : 'Sources: ${titles.join(' · ')}';
}

/// Title of the trace panel under a council answer.
const councilTraceTitle = 'How the council answered';

String _count(int n, String what) => '$n $what${n == 1 ? '' : 's'}';

String _expertLabel(CouncilConsult c) {
  final name = c.field ?? c.expert.replaceAll('_', ' ');
  return name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';
}

const _providerNames = {'meta': 'Muse', 'nebius': 'Nebius', 'openrouter_poc': 'a test model', 'opencode_poc': 'a test model'};

/// Which brain answered, from [CouncilResult.providers] in the order used:
/// "Answered by: Muse", or "Answered by: Muse, then Nebius (fallback)" when a
/// later provider took over. Null when the list is empty.
String? answeredByLine(List<String> providers) {
  final names = <String>[];
  for (final p in providers) {
    final n = _providerNames[p] ?? 'another model';
    if (!names.contains(n)) names.add(n);
  }
  if (names.isEmpty) return null;
  return 'Answered by: ${[names.first, for (final n in names.skip(1)) 'then $n (fallback)'].join(', ')}';
}

/// The trace as panel lines: one per expert ("Sleep and lifestyle: 3
/// sources, web search not needed"; an expert asked twice is one line), then
/// the web search line, then [answeredByLine] for [providers], then a line for
/// a limit the run closed on. Empty when there is nothing to show.
List<String> councilTraceLines(CouncilTrace t, {List<String> providers = const []}) {
  final byExpert = <String, List<CouncilConsult>>{};
  for (final c in t.consults) {
    byExpert.putIfAbsent(c.expert, () => []).add(c);
  }
  final lines = <String>[];
  final searchedFor = <String>[];
  var unavailable = false, tavily = false;
  for (final cs in byExpert.values) {
    final label = _expertLabel(cs.first);
    final seen = <(String, bool)>{};
    for (final c in cs) {
      for (final s in c.sources) {
        seen.add((s.title, s.web));
      }
    }
    final web = seen.where((s) => s.$2).length, bank = seen.length - web;
    final used = cs.any((c) => c.webSearch == WebSearch.used);
    final missing = !used && cs.any((c) => c.webSearch == WebSearch.unavailable);
    if (used) searchedFor.add(label);
    unavailable |= missing;
    tavily |= cs.any((c) => c.webSearch == WebSearch.used && c.webVia == 'tavily');
    if (!cs.any((c) => c.answered)) {
      lines.add('$label: did not answer');
      continue;
    }
    final sources = switch ((bank, web)) {
      (0, 0) => 'no sources',
      (_, 0) => _count(bank, 'source'),
      (0, _) => _count(web, 'web source'),
      _ => '$bank bank and ${_count(web, 'web source')}',
    };
    final search = used ? 'web search used' : (missing ? 'web search unavailable' : 'web search not needed');
    lines.add('$label: $sources, $search');
  }
  if (byExpert.isNotEmpty) {
    final name = tavily ? 'Web search (Tavily)' : 'Web search';
    lines.add(searchedFor.isNotEmpty
        ? '$name: ran for ${searchedFor.join(', ')}'
        : unavailable
            ? '$name: unavailable'
            : '$name: not needed');
  }
  if (answeredByLine(providers) case final a?) lines.add(a);
  for (final n in t.notes) {
    if (n == 'time_limit') lines.add('The council closed at its time limit.');
    if (n == 'consult_limit') lines.add('The council closed at its consult limit.');
  }
  return lines;
}

/// Speaks a council answer and then shows its sources and its trace.
class CouncilSpeaker {
  const CouncilSpeaker({required this.speak, this.caption, this.trace});
  final AsideSpeak speak;
  final AsideCaption? caption;

  /// Gets the trace lines ([councilTraceLines]) after a whole answer played.
  final void Function(List<String> lines)? trace;

  /// True when the whole answer played (sources and trace show only then).
  Future<bool> say(CouncilResult r) async {
    if (!await sayText(r.synthesis, medical: r.medical, sources: r.crisis ? const [] : r.sources)) return false;
    final lines = r.crisis ? const <String>[] : councilTraceLines(r.trace, providers: r.providers);
    if (lines.isNotEmpty) trace?.call(lines);
    return true;
  }

  Future<bool> sayText(String text, {bool medical = false, List<CouncilSource> sources = const []}) async {
    if (!await speak(withMedicalLine(text, medical))) return false;
    final c = sourcesCaption(sources);
    if (c != null) caption?.call(c);
    return true;
  }
}

/// `context.short_term_summary` for the council: the last session
/// summaries and the newest turns of this conversation, newest kept when
/// it must be cut (CouncilContext caps it at 2000 characters).
CouncilContext councilContextFrom(ShortTermMemory? shortTerm, {int turns = 6}) {
  if (shortTerm == null) return const CouncilContext();
  final c = shortTerm.context();
  final recent = c.turns.length <= turns ? c.turns : c.turns.sublist(c.turns.length - turns);
  final lines = [
    for (final s in c.summaries) 'Earlier: $s',
    for (final t in recent) '${t.role == SessionTurn.user ? 'User' : 'Illunis'}: ${t.text}',
  ];
  return CouncilContext(shortTermSummary: lines.isEmpty ? null : lines.join('\n'));
}

/// How long the council offer waits for its answer: 8 s for a spoken one
/// (the microphone listens right after the question), and as long as the
/// view offers ([ViewOffer.timeout], 90 s) for a typed one.
Duration councilOfferTimeout({required bool voice}) => voice ? const Duration(seconds: 8) : ViewOffer.timeout;

class CouncilFlow {
  CouncilFlow({
    required this.server,
    required this.speaker,
    required this.speak,
    this.listen,
    CouncilContext Function()? context,
    this.onAnswer,
    bool Function()? quiet,
    OneShotTimer? timer,
    this.answerTimeout = const Duration(seconds: 8),
    this.declineCooldown = const Duration(minutes: 10),
    DateTime Function()? clock,
    AsideLog? log,
  })  : _context = context ?? (() => const CouncilContext()),
        _quiet = quiet ?? (() => true),
        _timer = timer ?? realTimer,
        _clock = clock ?? DateTime.now,
        _log = log ?? debugPrint;

  final ServerPort server;
  final CouncilSpeaker speaker;

  /// Prompts ("Want me to ask the council?").
  final AsideSpeak speak;
  final AsideListen? listen;

  /// Called with the question and the spoken synthesis (short-term memory).
  final void Function(String question, String synthesis)? onAnswer;

  /// Silence after the offer closes it without a word.
  final Duration answerTimeout;

  /// After a "no", no new offer for this long.
  final Duration declineCooldown;

  final CouncilContext Function() _context;

  /// True when nothing else is speaking or listening; the answer waits for it.
  final bool Function() _quiet;
  final OneShotTimer _timer;
  final DateTime Function() _clock;
  final AsideLog _log;

  String? _offered;
  String? _lastQuestion;
  Timer? _offerTimer;
  bool _running = false;
  DateTime? _declinedAt;
  Future<void> _queue = Future.value();

  bool get offerOpen => _offered != null;
  bool get running => _running;

  /// True while the offer waits for an answer or the council runs.
  bool get busy => offerOpen || _running;
  Future<void> get settled => _queue;

  /// For [AppController.afterAnswer]: offers the council after a big question.
  void afterAnswer(AnsweredTurn t) {
    final big = t.councilSuggested || councilTrigger(t.transcript) == CouncilTrigger.offer;
    if (!big) return;
    _lastQuestion = t.transcript;
    final d = _declinedAt;
    if (d != null && _clock().difference(d) < declineCooldown) return;
    if (busy) return;
    _queue = _queue.then((_) => _offer(t.transcript));
  }

  Future<void> _offer(String question) async {
    if (busy) return;
    _offered = question;
    _log('council: offered');
    if (!await speak(CouncilPrompt.offer) || _offered != question) {
      _closeOffer();
      return;
    }
    listen?.call();
    _offerTimer = _timer(answerTimeout, () {
      if (_offered == null) return;
      _log('council: offer_timeout');
      _closeOffer();
    });
  }

  void _closeOffer() {
    _offerTimer?.cancel();
    _offerTimer = null;
    _offered = null;
  }

  /// Takes the answer to an open offer (yes runs the council, no closes it,
  /// anything else closes it and is left for normal handling), and an
  /// explicit "ask the council ..." at any time.
  bool claim(String text) {
    final offered = _offered;
    if (offered != null) {
      final a = parseOfferAnswer(text);
      _closeOffer();
      if (a == true) {
        _queue = _queue.then((_) => _ask(offered));
        return true;
      }
      if (a == false) {
        _declinedAt = _clock();
        _log('council: declined');
        _queue = _queue.then((_) => speak(CouncilPrompt.declined));
        return true;
      }
      _log('council: offer_dropped');
    }
    if (councilTrigger(text) != CouncilTrigger.explicit) return false;
    final q = explicitCouncilQuestion(text) ?? _lastQuestion;
    _queue = _queue.then((_) => q == null ? speak(CouncilPrompt.needQuestion) : _ask(q));
    return true;
  }

  /// Sends [question] to the council and speaks the answer.
  Future<void> ask(String question) => _queue = _queue.then((_) => _ask(question));

  Future<void> _ask(String question) async {
    if (_running) return;
    _running = true;
    try {
      _lastQuestion = question;
      await speak(CouncilPrompt.asking);
      final CouncilResult r;
      try {
        r = await server.council(question: question, context: _context(), purpose: 'chat');
      } catch (e) {
        _log('council: failed code=${asideCode(e)}');
        await speak(CouncilPrompt.unavailable);
        return;
      }
      // Never over the user or another reply.
      if (!await waitForQuiet(_quiet)) {
        _log('council: answer_dropped code=busy');
        return;
      }
      _log('council: answered experts=${r.expertsConsulted.length} sources=${r.sources.length} providers=${r.providers.join(',')}');
      if (await speaker.say(r) && !r.crisis) onAnswer?.call(question, withMedicalLine(r.synthesis, r.medical));
    } finally {
      _running = false;
    }
  }

  void dispose() => _closeOffer();
}
