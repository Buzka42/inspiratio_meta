/// Client side of the Worker API. Shapes follow server/src/index.js,
/// router.js, turn.js, digest.js, council/relay.js, analysis/run21d.js and
/// assistants/routes.js. POST /router, /turn, /digest, /council (v2),
/// /analysis/21d, /reply, /reply/stream, /memory/write, /session/summary,
/// /assistant/memory/{write,recall}, /assistant/message,
/// /assistant/action/{propose,confirm}, GET /assistant/inbox, GET /spec,
/// POST /spec/{propose,apply} and GET /knowledge/sources are used. A
/// voice turn is POST /turn first, then POST /reply/stream (or /reply) with
/// the plan /turn returned. /reply/stream is SSE (server/src/reply-stream.js).
///
/// /turn and /reply carry the phone's [PhoneContext] as two extra top-level
/// fields (`short_term`, `memories`) when the caller passes one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../memory/memory_note.dart';
import '../memory/phone_context.dart';
import '../memory/short_term_memory.dart';
import 'settings_spec.dart';

/// Result of POST /router `{transcript}`. Rules only; it is NOT a reply
/// plan (POST /reply takes the plan from POST /turn, see [TurnPlan]).
class RouteResult {
  const RouteResult({
    this.personalityId,
    this.skillId,
    this.escalate = false,
    this.crisis = false,
    this.response,
  });

  final String? personalityId;
  final String? skillId;

  /// True when no rule matched (a later small-model call should decide),
  /// and on crisis.
  final bool escalate;
  final bool crisis;

  /// Fixed referral text, present only on crisis.
  final String? response;

  factory RouteResult.fromJson(Map<String, dynamic> j) => RouteResult(
        personalityId: j['personality_id'] as String?,
        skillId: j['skill_id'] as String?,
        escalate: j['escalate'] == true,
        crisis: j['crisis'] == true,
        response: j['response'] as String?,
      );
}

/// Result of POST /turn `{transcript, context}` (server/src/turn.js).
/// On crisis only [crisis], [escalate] and the fixed [response] matter.
class TurnPlan {
  const TurnPlan({
    this.personalityId,
    this.skillId,
    this.escalate = false,
    this.crisis = false,
    this.response,
  });

  final String? personalityId;
  final String? skillId;
  final bool escalate;
  final bool crisis;

  /// Fixed referral text, present only on crisis.
  final String? response;

  /// The server's `system_prompt` and `memories` are deliberately not kept:
  /// /reply rebuilds both from ids and its own store, so they are never sent
  /// back (no memory text leaves the client, no ignored-field warnings).
  factory TurnPlan.fromJson(Map<String, dynamic> j) => TurnPlan(
        personalityId: j['personality_id'] as String?,
        skillId: j['skill_id'] as String?,
        escalate: j['escalate'] == true,
        crisis: j['crisis'] == true,
        response: j['response'] as String?,
      );

  /// The `plan` sent to POST /reply. Never used on crisis.
  Map<String, dynamic> toReplyPlan() => {'personality_id': personalityId, 'skill_id': skillId};
}

/// Result of POST /reply `{plan, transcript}`.
class ReplyResult {
  const ReplyResult({required this.text, this.personalityId, this.safety, this.councilSuggested = false});
  final String text;
  final String? personalityId;

  /// The server's safety block, kept opaque (shape owned by the server).
  final Object? safety;

  /// The reply model's flag that the question needs specialist depth
  /// (`council_suggested: true`). Today's Worker does not send it; when it
  /// is absent the phone's own rules decide (council_flow.dart).
  final bool councilSuggested;

  factory ReplyResult.fromJson(Map<String, dynamic> j) => ReplyResult(
        text: j['text'] as String? ?? '',
        personalityId: j['personality_id'] as String?,
        safety: j['safety'],
        councilSuggested: j['council_suggested'] == true,
      );
}

/// One event of POST /reply/stream (server/src/reply-stream.js).
sealed class ReplyStreamEvent {
  const ReplyStreamEvent();

  /// The typed event for [e], or null for an event name this client does not
  /// know. Bad JSON in a known event is an `invalid_event` error.
  static ReplyStreamEvent? fromSse(SseEvent e) {
    if (!const {'sentence', 'done', 'error'}.contains(e.event)) return null;
    Object? j;
    try {
      j = jsonDecode(e.data);
    } on FormatException {
      j = null;
    }
    if (j is! Map<String, dynamic>) return const ReplyStreamError('invalid_event');
    return switch (e.event) {
      'sentence' => ReplySentence(j['text'] as String? ?? ''),
      'done' => ReplyStreamDone(
          text: j['text'] as String? ?? '',
          personalityId: j['personality_id'] as String?,
          safety: j['safety'],
          health: j['health'] == true,
          councilSuggested: j['council_suggested'] == true,
        ),
      _ => ReplyStreamError(j['error'] as String? ?? 'reply_error'),
    };
  }
}

/// A gated sentence, in order.
class ReplySentence extends ReplyStreamEvent {
  const ReplySentence(this.text);
  final String text;
}

/// The last piece of the reply. [safety] is "passed" or "replaced"; on
/// "replaced" [text] is the fixed referral. Last event of the stream.
class ReplyStreamDone extends ReplyStreamEvent {
  const ReplyStreamDone(
      {required this.text, this.personalityId, this.safety, this.health = false, this.councilSuggested = false});
  final String text;
  final String? personalityId;
  final Object? safety;
  final bool health;

  /// See [ReplyResult.councilSuggested].
  final bool councilSuggested;

  bool get replaced => safety == 'replaced';
}

/// A fixed server code (reply_upstream, reply_timeout). Last event.
class ReplyStreamError extends ReplyStreamEvent {
  const ReplyStreamError(this.error);
  final String error;
}

/// One server-sent event. [event] defaults to `message`.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;

  @override
  bool operator ==(Object other) => other is SseEvent && other.event == event && other.data == data;
  @override
  int get hashCode => Object.hash(event, data);
  @override
  String toString() => 'SseEvent($event)';
}

/// Incremental text/event-stream parser. Feed decoded text in any chunking
/// with [add]; [close] flushes a last event that has no final newline.
/// Lines end in \n, \r\n or \r (a \r\n split across chunks is one end).
/// Several `data:` lines join with \n; `:` comment lines and unknown fields
/// are ignored; an event with no data line is dropped.
class SseParser {
  final _line = StringBuffer();
  final _data = <String>[];
  String? _event;
  bool _afterCr = false;

  List<SseEvent> add(String chunk) {
    final out = <SseEvent>[];
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk[i];
      if (ch == '\n' && _afterCr) {
        _afterCr = false;
        continue;
      }
      _afterCr = ch == '\r';
      if (ch == '\n' || ch == '\r') {
        _endLine(out);
      } else {
        _line.write(ch);
      }
    }
    return out;
  }

  List<SseEvent> close() {
    final out = <SseEvent>[];
    if (_line.isNotEmpty) _endLine(out);
    _dispatch(out);
    _afterCr = false;
    return out;
  }

  void _endLine(List<SseEvent> out) {
    final line = _line.toString();
    _line.clear();
    if (line.isEmpty) return _dispatch(out);
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') _event = value;
    if (field == 'data') _data.add(value);
  }

  void _dispatch(List<SseEvent> out) {
    if (_data.isNotEmpty) out.add(SseEvent(_event ?? 'message', _data.join('\n')));
    _data.clear();
    _event = null;
  }
}

/// Parses a whole text/event-stream body (pure; see [SseParser]).
List<SseEvent> parseSse(String body) {
  final p = SseParser();
  return [...p.add(body), ...p.close()];
}

/// Cancels a pending request (barge-in). Callbacks run once, synchronously.
class CancelToken {
  bool _cancelled = false;
  final _callbacks = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final c in List.of(_callbacks)) {
      c();
    }
    _callbacks.clear();
  }

  void onCancel(void Function() c) => _cancelled ? c() : _callbacks.add(c);
}

/// One finding sent to POST /digest. Phrased as an observation.
class Finding {
  const Finding(this.text, {this.kind, this.confidence});
  final String text;

  /// "health" makes the server attach the not-medical-advice line.
  final String? kind;
  final double? confidence;

  Map<String, dynamic> toJson() => {
        'text': text,
        if (kind != null) 'kind': kind,
        if (confidence != null) 'confidence': confidence,
      };
}

/// Result of POST /digest `{personality_id, findings, skill_pack_id?}`.
/// The server runs the council inside /digest (purpose `digest`) unless the
/// body says `council: false`; [council] is null when it did not run or
/// failed, and [councilCode] then says why. A council failure never fails
/// the digest.
class DigestResult {
  const DigestResult({required this.text, this.health = false, this.disclaimer, this.council, this.councilCode});
  final String text;
  final bool health;
  final String? disclaimer;
  final CouncilResult? council;
  final String? councilCode;

  factory DigestResult.fromJson(Map<String, dynamic> j) {
    final c = j['council'];
    final council = c is Map<String, dynamic> ? CouncilResult.fromJson(c) : null;
    return DigestResult(
      text: j['text'] as String? ?? '',
      health: j['health'] == true,
      disclaimer: j['disclaimer'] as String?,
      council: council == null || council.synthesis.isEmpty ? null : council,
      councilCode: j['council_code'] as String?,
    );
  }
}

/// One source the council cited: a knowledge-bank note or a web result
/// (`kind: "web"`). Only [title] is ever shown, briefly, as a caption.
class CouncilSource {
  const CouncilSource({required this.id, required this.title, this.url, this.kind});
  final String id;
  final String title;
  final String? url;
  final String? kind;

  static CouncilSource? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], title = j['title'];
    if (id is! String || title is! String || title.trim().isEmpty) return null;
    final url = j['url'], kind = j['kind'];
    return CouncilSource(
        id: id, title: title.trim(), url: url is String ? url : null, kind: kind is String ? kind : null);
  }
}

List<String> _strings(Object? v) => [
      for (final e in (v is List ? v : const []))
        if (e is String) e,
    ];

List<CouncilSource> _sources(Object? v) => [
      for (final e in (v is List ? v : const [])) ?CouncilSource.fromJson(e),
    ];

/// Whether a consult searched the web (relay.js trace `web_search`).
enum WebSearch { used, unavailable, notNeeded }

/// One source a consult drew on, by kind (relay.js trace `sources`).
class CouncilTraceSource {
  const CouncilTraceSource(this.title, {this.web = false});
  final String title;
  final bool web;
}

/// One consult in the council trace (relay.js, T18): which expert, what the
/// relay asked, the sources it was given and whether web search ran. A real
/// record from the server; it holds no model text beyond [question].
class CouncilConsult {
  const CouncilConsult({
    required this.expert,
    this.field,
    this.question = '',
    this.sources = const [],
    this.webSearch = WebSearch.notNeeded,
    this.webVia,
    this.answered = true,
  });
  final String expert;
  final String? field;
  final String question;
  final List<CouncilTraceSource> sources;
  final WebSearch webSearch;

  /// "tavily" or "meta" when [webSearch] is used.
  final String? webVia;
  final bool answered;

  static const _web = {'used': WebSearch.used, 'unavailable': WebSearch.unavailable, 'not_needed': WebSearch.notNeeded};

  static CouncilConsult? fromJson(Map j) {
    final expert = j['expert'];
    if (expert is! String || expert.isEmpty) return null;
    final field = j['field'], question = j['question'], via = j['web_via'];
    return CouncilConsult(
      expert: expert,
      field: field is String && field.trim().isNotEmpty ? field.trim() : null,
      question: question is String ? question : '',
      sources: [
        for (final s in (j['sources'] is List ? j['sources'] as List : const []))
          if (s is Map && s['title'] is String) CouncilTraceSource(s['title'] as String, web: s['kind'] == 'web'),
      ],
      webSearch: _web[j['web_search']] ?? WebSearch.notNeeded,
      webVia: via is String ? via : null,
      answered: j['answered'] != false,
    );
  }
}

/// The council trace: the consults in call order and the limits the run
/// closed on (`time_limit`, `consult_limit`).
class CouncilTrace {
  const CouncilTrace({this.consults = const [], this.notes = const []});
  final List<CouncilConsult> consults;
  final List<String> notes;
  bool get isEmpty => consults.isEmpty && notes.isEmpty;

  factory CouncilTrace.fromJson(Object? v) {
    final consults = <CouncilConsult>[], notes = <String>[];
    for (final e in (v is List ? v : const [])) {
      if (e is! Map) continue;
      if (e['note'] case final String n) {
        notes.add(n);
      } else if (CouncilConsult.fromJson(e) case final c?) {
        consults.add(c);
      }
    }
    return CouncilTrace(consults: consults, notes: notes);
  }
}

/// The council's answer (server/src/council/relay.js `assemble`, or the
/// `council` view inside a /digest answer). [synthesis] is already gated on
/// the server; when [medical] it already ends with the not-medical-advice
/// line and the clinician path. On crisis [synthesis] is the fixed referral.
class CouncilResult {
  const CouncilResult({
    required this.synthesis,
    this.expertsConsulted = const [],
    this.sources = const [],
    this.medical = false,
    this.crisis = false,
    this.purpose,
    this.providers = const [],
    this.limitsHit = const [],
    this.adviseOnly = true,
    this.trace = const CouncilTrace(),
  });
  final String synthesis;
  final List<String> expertsConsulted;
  final List<CouncilSource> sources;
  final bool medical;
  final bool crisis;
  final String? purpose;
  final List<String> providers;
  final List<String> limitsHit;
  final bool adviseOnly;

  /// Empty when the server sent none (legacy council, digest view, crisis).
  final CouncilTrace trace;

  factory CouncilResult.fromJson(Map<String, dynamic> j) => CouncilResult(
        synthesis: (j['synthesis'] as String? ?? '').trim(),
        expertsConsulted: _strings(j['experts_consulted']),
        sources: _sources(j['sources']),
        medical: j['medical'] == true,
        crisis: j['crisis'] == true,
        purpose: j['purpose'] as String?,
        providers: _strings(j['providers']),
        limitsHit: _strings(j['limits_hit']),
        adviseOnly: j['advise_only'] != false,
        trace: CouncilTrace.fromJson(j['trace']),
      );
}

/// Council v2 `context`: `{short_term_summary?, signals?}` (server/src/index.js
/// contextProblem: summary at most 2000 characters, signals an object).
class CouncilContext {
  const CouncilContext({this.shortTermSummary, this.signals});
  final String? shortTermSummary;
  final Map<String, dynamic>? signals;

  static const maxSummary = 2000;

  Map<String, dynamic> toJson() {
    final s = shortTermSummary?.trim();
    return {
      if (s != null && s.isNotEmpty) 'short_term_summary': s.length <= maxSummary ? s : s.substring(s.length - maxSummary),
      'signals': ?signals,
    };
  }
}

/// Result of POST /analysis/21d (server/src/analysis/run21d.js). [comment] is
/// the council's short comment, already number-checked on the server, or
/// null with [commentCode] saying why (nothing_to_comment,
/// council_not_configured, council_upstream, comment_*). On crisis only
/// [crisis] and [text] (the fixed referral) are set. The raw findings stay
/// on the server side of this type: nothing else is spoken.
class AnalysisResult {
  const AnalysisResult({
    this.crisis = false,
    this.text,
    this.comment,
    this.commentCode,
    this.notice,
    this.sources = const [],
    this.medical = false,
    this.expertsConsulted = const [],
  });
  final bool crisis;
  final String? text;
  final String? comment;
  final String? commentCode;
  final String? notice;
  final List<CouncilSource> sources;
  final bool medical;
  final List<String> expertsConsulted;

  factory AnalysisResult.fromJson(Map<String, dynamic> j) {
    final c = j['council'];
    final council = c is Map<String, dynamic> ? c : const <String, dynamic>{};
    final comment = j['comment'];
    return AnalysisResult(
      crisis: j['crisis'] == true,
      text: j['text'] as String?,
      comment: comment is String && comment.trim().isNotEmpty ? comment.trim() : null,
      commentCode: j['comment_code'] as String?,
      notice: j['notice'] as String?,
      sources: _sources(council['sources']),
      medical: council['medical'] == true,
      expertsConsulted: _strings(council['experts_consulted']),
    );
  }
}

/// A pending action from POST /assistant/action/propose: the Worker builds
/// [readback] from the action itself, so what is spoken is what is signed.
/// The confirm window is [expiresIn] seconds (60 on the server).
class ActionProposal {
  const ActionProposal({required this.actionId, required this.readback, this.expiresIn = 60});
  final String actionId;
  final String readback;
  final int expiresIn;

  static final _id = RegExp(r'^act_[0-9a-f]{32}$');

  /// Null unless the id has the Worker's shape and the readback is text.
  static ActionProposal? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['action_id'], rb = j['readback'], exp = j['expires_in'];
    if (id is! String || !_id.hasMatch(id) || rb is! String || rb.trim().isEmpty) return null;
    return ActionProposal(actionId: id, readback: rb.trim(), expiresIn: exp is num ? exp.toInt() : 60);
  }
}

/// POST /assistant/action/propose answered 422 action_refused. [code] is
/// `crisis` (then [referral] is the fixed referral text) or `gate`.
class ActionRefused implements Exception {
  const ActionRefused(this.code, {this.referral});
  final String code;
  final String? referral;
  @override
  String toString() => 'ActionRefused($code)';
}

/// Result of POST /assistant/action/confirm: [status] is done, queued or
/// failed. The bot's detail is never spoken.
class ActionOutcome {
  const ActionOutcome({required this.actionId, required this.status});
  final String actionId;
  final String status;

  factory ActionOutcome.fromJson(Map<String, dynamic> j) =>
      ActionOutcome(actionId: j['action_id'] as String? ?? '', status: j['status'] as String? ?? 'failed');
}

/// Result of POST /assistant/message `{text, context?}`: the bot's answer
/// after the Worker's gate. A later Worker may add a `proposal`
/// ({action_id, readback, expires_in}) when the bot wants to act; it then
/// goes through the voice approval flow.
class AssistantReply {
  const AssistantReply({required this.text, this.safety, this.health = false, this.proposal});
  final String text;
  final String? safety;
  final bool health;
  final ActionProposal? proposal;

  factory AssistantReply.fromJson(Map<String, dynamic> j) => AssistantReply(
        text: (j['text'] as String? ?? '').trim(),
        safety: j['safety'] as String?,
        health: j['health'] == true,
        proposal: ActionProposal.fromJson(j['proposal']),
      );
}

/// One item pushed by the assistant (kind: message, reminder, bot_reply,
/// action_result, memory). [text] is gated on the server.
class InboxItem {
  const InboxItem({required this.id, required this.kind, required this.text, required this.ts});
  final String id;
  final String kind;
  final String text;
  final int ts;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'text': text, 'ts': ts};

  static InboxItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], kind = j['kind'], text = j['text'], ts = j['ts'];
    if (id is! String || id.isEmpty || kind is! String || text is! String || text.trim().isEmpty || ts is! num) {
      return null;
    }
    return InboxItem(id: id, kind: kind, text: text.trim(), ts: ts.toInt());
  }

  @override
  bool operator ==(Object other) => other is InboxItem && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// GET /assistant/inbox: up to 20 items in order; the server marks them read.
class InboxBatch {
  const InboxBatch({this.items = const [], this.more = false});
  final List<InboxItem> items;
  final bool more;

  factory InboxBatch.fromJson(Map<String, dynamic> j) => InboxBatch(
        items: [for (final i in (j['items'] is List ? j['items'] as List : const [])) ?InboxItem.fromJson(i)],
        more: j['more'] == true,
      );
}

/// One food calorie mismatch from POST /log/parse `needs_choice` (C6). The
/// user's number and the one found are both shown; nothing changes silently.
class FoodChoice {
  const FoodChoice({
    required this.itemIndex,
    required this.userValue,
    required this.foundValue,
    this.sourceUrl,
    this.sourceTitle,
  });
  final int itemIndex;

  /// The kcal the user wrote for that item.
  final num userValue;

  /// The kcal the source gives, scaled to the quantity.
  final num foundValue;
  final String? sourceUrl;
  final String? sourceTitle;

  /// Null for a row that is not a well-formed choice.
  static FoodChoice? fromJson(Object? j) {
    if (j is! Map) return null;
    final i = j['item_index'];
    final u = j['user_value'];
    final f = j['found_value'];
    if (i is! int || i < 0 || u is! num || f is! num) return null;
    if (j['field'] != 'kcal') return null;
    return FoodChoice(
      itemIndex: i,
      userValue: u,
      foundValue: f,
      sourceUrl: j['source_url'] as String?,
      sourceTitle: j['source_title'] as String?,
    );
  }
}

/// Answer of POST /log/parse (server/src/logs/parse.js). Exactly one of:
/// [envelope] (ok, the `illunis.log/1` envelope as sent), [crisis] (the fixed
/// [referral] text), [choice] (a food mismatch: [pending] is the envelope
/// the user has not saved, [choices] the rows to pick from), or a rejected
/// model answer with its fixed [code] (`bad_json`, `number_not_in_text`,
/// ...). Never carries the user's text beyond the pending entry.
class LogParseResult {
  const LogParseResult.parsed(Map<String, dynamic> this.envelope)
      : code = null,
        crisis = false,
        referral = null,
        pending = null,
        choices = const [];
  const LogParseResult.rejected(String this.code)
      : envelope = null,
        crisis = false,
        referral = null,
        pending = null,
        choices = const [];
  const LogParseResult.crisis(String this.referral)
      : envelope = null,
        code = 'crisis',
        crisis = true,
        pending = null,
        choices = const [];
  const LogParseResult.choice(this.pending, this.choices)
      : envelope = null,
        code = 'needs_choice',
        crisis = false,
        referral = null;

  final Map<String, dynamic>? envelope;
  final String? code;
  final bool crisis;
  final String? referral;

  /// The unsaved envelope of a `needs_choice` answer.
  final Map<String, dynamic>? pending;
  final List<FoodChoice> choices;
  bool get ok => envelope != null;

  /// Null for a body that is none of the shapes. `ok: false` with
  /// `code: needs_choice` and a valid `needs_choice` list is a choice; any
  /// other `ok: false` is a rejection, as before.
  static LogParseResult? fromJson(Map<String, dynamic> j) {
    if (j['ok'] == true) return LogParseResult.parsed(j);
    if (j['crisis'] == true && j['text'] is String) return LogParseResult.crisis(j['text'] as String);
    if (j['ok'] == false && j['code'] == 'needs_choice' && j['needs_choice'] is List && j['pending'] is Map) {
      final rows = [for (final r in j['needs_choice'] as List) FoodChoice.fromJson(r)];
      if (rows.isNotEmpty && !rows.contains(null)) {
        return LogParseResult.choice(Map<String, dynamic>.from(j['pending'] as Map), rows.cast<FoodChoice>());
      }
    }
    if (j['ok'] == false && j['code'] is String) return LogParseResult.rejected(j['code'] as String);
    return null;
  }
}

/// Non-2xx answer. [error] is the server code (bad_request, not_configured,
/// upstream_error, not_found). Never carries request payloads.
class ServerException implements Exception {
  const ServerException(this.status, this.error, [this.detail, this.code]);
  final int status;
  final String error;
  final String? detail;

  /// The server's sub-code (`code` field), when it sends one.
  final String? code;
  @override
  String toString() => 'ServerException($status, $error)';
}

abstract class ServerPort {
  Future<RouteResult> route(String transcript);

  /// POST /turn: crisis check, route and recall on the server. A cancelled
  /// [cancel] aborts it like [reply].
  Future<TurnPlan> turn({
    required String transcript,
    Map<String, dynamic> context = const {},
    PhoneContext? phone,
    CancelToken? cancel,
  });

  /// POST /digest. [context] goes to the server's digest council run
  /// (`context.short_term_summary`); [council] false asks for no council run.
  Future<DigestResult> digest({
    required String personalityId,
    required List<Finding> findings,
    String? skillPackId,
    CouncilContext? context,
    bool council = true,
  });

  /// POST /council v2 `{question, context?, purpose}`; [purpose] is chat,
  /// digest or analysis.
  Future<CouncilResult> council({
    required String question,
    CouncilContext? context,
    String purpose = 'chat',
  });

  /// POST /analysis/21d with the body from AnalysisInput.toJson.
  Future<AnalysisResult> analysis21d(Map<String, dynamic> body);

  /// POST /assistant/message `{text, context?}` (context at most 4000).
  Future<AssistantReply> assistantMessage(String text, {String? context});

  /// POST /assistant/action/propose `{request}`. A 422 action_refused fails
  /// with [ActionRefused]; other non-2xx with [ServerException].
  Future<ActionProposal> assistantPropose(String request);

  /// POST /assistant/action/confirm `{action_id, confirm_phrase_heard: true}`.
  /// Called only after the user said an explicit yes. 410 action_expired
  /// and 404 action_unknown fail with [ServerException].
  Future<ActionOutcome> assistantConfirm(String actionId);

  /// GET /assistant/inbox?limit=N. The server marks the items read.
  Future<InboxBatch> assistantInbox({int limit = 20});

  /// POST /reply. A cancelled [cancel] aborts the request; the future then
  /// fails with [ServerException] code `cancelled`.
  Future<ReplyResult> reply({
    required Map<String, dynamic> plan,
    required String transcript,
    PhoneContext? phone,
    CancelToken? cancel,
  });

  /// POST /reply/stream: the same body as [reply], answered as SSE. Yields
  /// [ReplySentence]s, then one [ReplyStreamDone] or [ReplyStreamError], then
  /// ends. A non-2xx answer fails with [ServerException] (its status and
  /// code); a stream that ends or breaks before its last event fails with
  /// code `stream_dropped`; a cancelled [cancel] aborts the read and fails
  /// with code `cancelled`.
  Stream<ReplyStreamEvent> replyStream({
    required Map<String, dynamic> plan,
    required String transcript,
    PhoneContext? phone,
    CancelToken? cancel,
  });

  /// POST /memory/write with [note] (server/src/memory.js validateMemory).
  /// The Worker's own store; the app writes through a MemoryBackend instead.
  /// A non-2xx answer fails with [ServerException].
  Future<void> memoryWrite(MemoryNote note);

  /// POST /session/summary `{turns: [{role, text}], started_at, ended_at}`
  /// -> `{summary}`. Stateless on the server. A missing or empty summary
  /// fails with [ServerException] code `invalid_response`.
  Future<String> sessionSummary({
    required List<SessionTurn> turns,
    required DateTime startedAt,
    required DateTime endedAt,
  });

  /// POST /assistant/memory/write with [MemoryNote.toJson] as the body.
  Future<void> assistantMemoryWrite(MemoryNote note);

  /// POST /assistant/memory/recall `{query, k}` ->
  /// `{items: [{text, kind, confidence, source, ...}]}` (the Worker's shape;
  /// `memories` is read as a fallback). Malformed entries are
  /// dropped; at most [k] are returned.
  Future<List<RecalledMemory>> assistantMemoryRecall(String query, {int k = 5});

  /// POST /log/parse `{kind, text, prefs:{effort}, date?}`. A 200 answer
  /// (parsed or crisis) and a 422 rejection with a fixed code both return a
  /// [LogParseResult]; other failures throw [ServerException]. [prefs] holds
  /// `effort`: `none`, `rir` or `rpe`. [date] is the phone's local day.
  Future<LogParseResult> parseLog(String kind, String text, {Map<String, String> prefs = const {}, String? date});

  /// GET /spec -> `{spec, guardrails, mirror}`.
  Future<SpecState> specGet();

  /// POST /spec/propose `{base_version, spec_patch?, request?}` -> a pending
  /// change. A 422 with `refused` fails with [SpecRefused]; 409 with
  /// [ServerException].
  Future<SpecProposal> specPropose({required int baseVersion, Map<String, dynamic>? patch, String? request});

  /// POST /spec/apply `{change_id}` -> the new [SpecState]. Only after the
  /// user approved the diff.
  Future<SpecState> specApply(String changeId);

  /// GET /knowledge/sources -> `{sources: [{id, title, origin, bank}]}`.
  Future<List<KnowledgeSource>> knowledgeSources();

  /// POST /knowledge/add `{base_version, source: {title, origin, date, text, bank}}`:
  /// a proposal like [specPropose], applied through [specApply]. [bank] is
  /// `reading` (the reading companion) or an expert id (e.g. `sleep_lifestyle`).
  Future<SpecProposal> knowledgeAdd({required int baseVersion, required String title, required String text, String bank = 'reading'});

  /// POST /knowledge/remove `{base_version, source_id}`.
  Future<SpecProposal> knowledgeRemove({required int baseVersion, required String sourceId});
}

/// Offline stand-in. Returns canned results and records every call.
class FakeServerPort implements ServerPort {
  FakeServerPort({
    this.routeResult = const RouteResult(personalityId: 'calm-guide', escalate: true),
    this.turnResult = const TurnPlan(personalityId: 'calm_guide'),
    this.digestResult = const DigestResult(text: 'Good morning.'),
    this.councilResult = const CouncilResult(synthesis: 'Synthetic council synthesis.'),
    this.replyResult = const ReplyResult(text: 'Synthetic reply.', personalityId: 'calm_guide'),
  });

  RouteResult routeResult;
  TurnPlan turnResult;
  DigestResult digestResult;
  CouncilResult councilResult;
  ReplyResult replyResult;

  /// When set, turn() / reply() throws it.
  Object? turnError;
  Object? replyError;

  /// When set, turn() / reply() waits for it (or for its cancel token).
  Completer<void>? turnGate;
  Completer<void>? replyGate;
  int turnCancels = 0;
  int replyCancels = 0;

  /// Every call in order, by path ("/turn", "/reply", ...).
  final calls = <String>[];
  final routeCalls = <String>[];
  final turnCalls = <({String transcript, Map<String, dynamic> context})>[];

  /// The [PhoneContext] of each turn / reply / replyStream call, in order.
  final turnPhones = <PhoneContext?>[];
  final replyPhones = <PhoneContext?>[];
  final digestCalls = <({String personalityId, String? skillPackId, List<Finding> findings})>[];

  /// The context and council flag of each digest() call, in order.
  final digestContexts = <({CouncilContext? context, bool council})>[];
  final councilCalls = <String>[];
  final councilRequests = <({String question, CouncilContext? context, String purpose})>[];

  /// When set, council() throws it.
  Object? councilError;

  /// When set, council() waits for it.
  Completer<void>? councilGate;
  final replyCalls = <({Map<String, dynamic> plan, String transcript})>[];

  @override
  Future<RouteResult> route(String transcript) async {
    calls.add('/router');
    routeCalls.add(transcript);
    return routeResult;
  }

  @override
  Future<TurnPlan> turn({
    required String transcript,
    Map<String, dynamic> context = const {},
    PhoneContext? phone,
    CancelToken? cancel,
  }) async {
    calls.add('/turn');
    turnCalls.add((transcript: transcript, context: context));
    turnPhones.add(phone);
    await _hold(turnGate, cancel, () => turnCancels++);
    final e = turnError;
    if (e != null) throw e;
    return turnResult;
  }

  /// Waits for [gate] unless [cancel] fires first; cancelled means a
  /// `cancelled` [ServerException], as the HTTP port reports it.
  static Future<void> _hold(Completer<void>? gate, CancelToken? cancel, void Function() onCancel) async {
    if (gate != null) {
      final done = Completer<void>();
      cancel?.onCancel(() {
        onCancel();
        if (!done.isCompleted) done.completeError(const ServerException(0, 'cancelled'));
      });
      unawaited(gate.future.then((_) {
        if (!done.isCompleted) done.complete();
      }));
      await done.future;
    }
    if (cancel?.isCancelled ?? false) throw const ServerException(0, 'cancelled');
  }

  @override
  Future<DigestResult> digest({
    required String personalityId,
    required List<Finding> findings,
    String? skillPackId,
    CouncilContext? context,
    bool council = true,
  }) async {
    calls.add('/digest');
    digestCalls.add((personalityId: personalityId, skillPackId: skillPackId, findings: findings));
    digestContexts.add((context: context, council: council));
    return digestResult;
  }

  @override
  Future<CouncilResult> council({
    required String question,
    CouncilContext? context,
    String purpose = 'chat',
  }) async {
    calls.add('/council');
    councilCalls.add(question);
    councilRequests.add((question: question, context: context, purpose: purpose));
    await councilGate?.future;
    final e = councilError;
    if (e != null) throw e;
    return councilResult;
  }

  /// analysis21d() bodies, the result returned, and an optional error.
  final analysisCalls = <Map<String, dynamic>>[];
  AnalysisResult analysisResult = const AnalysisResult(comment: 'Synthetic three-week comment.');
  Object? analysisError;

  @override
  Future<AnalysisResult> analysis21d(Map<String, dynamic> body) async {
    calls.add('/analysis/21d');
    analysisCalls.add(body);
    final e = analysisError;
    if (e != null) throw e;
    return analysisResult;
  }

  /// Assistant bridge: every call is also in [calls] by route.
  final assistantMessages = <({String text, String? context})>[];
  AssistantReply assistantReply = const AssistantReply(text: 'Synthetic assistant answer.', safety: 'passed');
  final proposeCalls = <String>[];
  ActionProposal proposal =
      const ActionProposal(actionId: 'act_00000000000000000000000000000001', readback: 'I will message synthetic-bot: hello');
  final confirmCalls = <String>[];
  ActionOutcome outcome = const ActionOutcome(actionId: 'act_00000000000000000000000000000001', status: 'done');

  /// Results for successive assistantInbox() calls; empty batches after.
  final inboxBatches = <InboxBatch>[];
  int inboxPolls = 0;

  /// When set, the matching call throws it.
  Object? messageError, proposeError, confirmError, inboxError;

  @override
  Future<AssistantReply> assistantMessage(String text, {String? context}) async {
    calls.add('/assistant/message');
    assistantMessages.add((text: text, context: context));
    final e = messageError;
    if (e != null) throw e;
    return assistantReply;
  }

  @override
  Future<ActionProposal> assistantPropose(String request) async {
    calls.add('/assistant/action/propose');
    proposeCalls.add(request);
    final e = proposeError;
    if (e != null) throw e;
    return proposal;
  }

  @override
  Future<ActionOutcome> assistantConfirm(String actionId) async {
    calls.add('/assistant/action/confirm');
    confirmCalls.add(actionId);
    final e = confirmError;
    if (e != null) throw e;
    return outcome;
  }

  @override
  Future<InboxBatch> assistantInbox({int limit = 20}) async {
    calls.add('GET /assistant/inbox');
    inboxPolls++;
    final e = inboxError;
    if (e != null) throw e;
    return inboxBatches.isEmpty ? const InboxBatch() : inboxBatches.removeAt(0);
  }

  @override
  Future<ReplyResult> reply({
    required Map<String, dynamic> plan,
    required String transcript,
    PhoneContext? phone,
    CancelToken? cancel,
  }) async {
    calls.add('/reply');
    replyCalls.add((plan: plan, transcript: transcript));
    replyPhones.add(phone);
    await _hold(replyGate, cancel, () => replyCancels++);
    final e = replyError;
    if (e != null) throw e;
    return replyResult;
  }

  /// replyStream() events. Null means one [ReplyStreamDone] carrying
  /// [replyResult]'s text.
  List<ReplyStreamEvent>? replyStreamEvents;

  /// When set, replyStream() returns this controller's stream instead, so a
  /// test can push events one at a time.
  StreamController<ReplyStreamEvent>? replyStreamSource;

  /// When set, replyStream() fails with it before any event.
  Object? replyStreamError;
  int replyStreamCancels = 0;
  final replyStreamCalls = <({Map<String, dynamic> plan, String transcript})>[];

  @override
  Stream<ReplyStreamEvent> replyStream({
    required Map<String, dynamic> plan,
    required String transcript,
    PhoneContext? phone,
    CancelToken? cancel,
  }) {
    calls.add('/reply/stream');
    replyStreamCalls.add((plan: plan, transcript: transcript));
    replyPhones.add(phone);
    cancel?.onCancel(() => replyStreamCancels++);
    return replyStreamSource?.stream ?? _streamEvents(cancel);
  }

  /// memoryWrite() notes, kept out of [calls] so turn-order checks stay
  /// about the voice routes. [memoryWriteError], when set, is thrown instead.
  final memoryWrites = <MemoryNote>[];
  Object? memoryWriteError;

  @override
  Future<void> memoryWrite(MemoryNote note) async {
    final e = memoryWriteError;
    if (e != null) throw e;
    memoryWrites.add(note);
  }

  /// sessionSummary() calls and the summary returned. [sessionSummaryError],
  /// when set, is thrown instead. Kept out of [calls].
  final sessionSummaryCalls = <({List<SessionTurn> turns, DateTime startedAt, DateTime endedAt})>[];
  String sessionSummaryResult = 'Synthetic session summary.';
  Object? sessionSummaryError;

  @override
  Future<String> sessionSummary({
    required List<SessionTurn> turns,
    required DateTime startedAt,
    required DateTime endedAt,
  }) async {
    sessionSummaryCalls.add((turns: turns, startedAt: startedAt, endedAt: endedAt));
    final e = sessionSummaryError;
    if (e != null) throw e;
    return sessionSummaryResult;
  }

  /// The assistant's store, as the fake keeps it: writes append, recall
  /// returns [assistantRecallResult] (capped at k). Kept out of [calls].
  final assistantWrites = <MemoryNote>[];
  final assistantRecallCalls = <({String query, int k})>[];
  List<RecalledMemory> assistantRecallResult = const [];
  Object? assistantError;

  @override
  Future<void> assistantMemoryWrite(MemoryNote note) async {
    final e = assistantError;
    if (e != null) throw e;
    assistantWrites.add(note);
  }

  @override
  Future<List<RecalledMemory>> assistantMemoryRecall(String query, {int k = 5}) async {
    assistantRecallCalls.add((query: query, k: k));
    final e = assistantError;
    if (e != null) throw e;
    return assistantRecallResult.take(k).toList();
  }

  /// Canned /log/parse answer; [logParseFor] wins when set.
  LogParseResult logParseResult = const LogParseResult.rejected('empty_entry');
  LogParseResult Function(String kind, String text)? logParseFor;

  /// Makes the next parseLog() answer a food mismatch (`needs_choice`).
  void cannedLogChoice(Map<String, dynamic> pending, List<FoodChoice> choices) =>
      logParseResult = LogParseResult.choice(pending, choices);

  /// When set, parseLog() throws it.
  Object? logParseError;

  /// When set, parseLog() waits for it.
  Completer<void>? logParseGate;
  final logParseCalls = <({String kind, String text, Map<String, String> prefs, String? date})>[];

  // Settings spec: in memory, same defaults as the Worker's DEFAULT_SPEC.
  SettingsSpec fakeSpec = const SettingsSpec();
  List<KnowledgeSource> fakeSources = const [
    KnowledgeSource(id: 'src-1', title: 'Sleep hygiene leaflet', origin: 'NHS', bank: 'sleep_lifestyle'),
  ];
  static const fakeGuardrails = [
    'A crisis message always gets the fixed referral first.',
    'Medical replies always carry the fixed medical line.',
    'Personal data leaves the phone only under the data mode.',
  ];
  final _pending = <String, ({SpecProposal proposal, SettingsSpec spec, List<KnowledgeSource> sources})>{};

  /// The fake's clock for `expires_at` (five minutes, as the Worker's
  /// PENDING_TTL_MS) and for the apply's 410 change_expired.
  DateTime Function() fakeClock = DateTime.now;

  /// Every specPropose request text (null for a patch) and specApply id.
  final specProposeCalls = <String?>[];
  final specApplyCalls = <String>[];

  /// When set, specPropose() / specApply() throws it.
  Object? specProposeError, specApplyError;
  var _changeSeq = 0;

  @override
  Future<SpecState> specGet() async => SpecState(spec: fakeSpec, guardrails: fakeGuardrails, mirror: 'off');

  @override
  Future<List<KnowledgeSource>> knowledgeSources() async => fakeSources;

  @override
  Future<SpecProposal> specPropose({required int baseVersion, Map<String, dynamic>? patch, String? request}) async {
    specProposeCalls.add(request);
    if (specProposeError case final e?) throw e;
    if (baseVersion != fakeSpec.version) throw const ServerException(409, 'stale_version');
    var p = patch;
    if (p == null) {
      final t = (request ?? '').toLowerCase();
      final off = t.contains('stop') || t.contains('off') || t.contains('disable');
      final hit = skillIds.where(t.contains).firstOrNull;
      if (hit == null || t.contains('disclaimer')) {
        throw const SpecRefused([('request', 'not_allowed')]);
      }
      p = {'skills': {hit: !off}};
    }
    if (p.keys.any((k) => !const {'skills', 'memory', 'proactivity', 'brain'}.contains(k))) {
      throw SpecRefused([(p.keys.first, 'unknown_key')]);
    }
    final next = SettingsSpec.fromJson(_merge(fakeSpec.toJson(), p));
    final diff = _diff(fakeSpec.toJson(), next.toJson());
    if (diff.isEmpty) throw const SpecRefused([('', 'no_change')]);
    return _stage(baseVersion, diff, next, fakeSources);
  }

  @override
  Future<SpecProposal> knowledgeAdd({required int baseVersion, required String title, required String text, String bank = 'reading'}) async {
    if (baseVersion != fakeSpec.version) throw const ServerException(409, 'stale_version');
    final src = KnowledgeSource(id: 'src-${fakeSources.length + 2}-$title', title: title, origin: 'you', bank: bank);
    return _stage(baseVersion, [SpecDiffEntry('knowledge.add', null, title)], fakeSpec, [...fakeSources, src]);
  }

  @override
  Future<SpecProposal> knowledgeRemove({required int baseVersion, required String sourceId}) async {
    if (baseVersion != fakeSpec.version) throw const ServerException(409, 'stale_version');
    final gone = fakeSources.where((s) => s.id == sourceId).firstOrNull;
    if (gone == null) throw const SpecRefused([('knowledge_remove', 'unknown_source')]);
    return _stage(baseVersion, [SpecDiffEntry('knowledge.remove', gone.title, null)], fakeSpec,
        [for (final s in fakeSources) if (s.id != sourceId) s]);
  }

  @override
  Future<SpecState> specApply(String changeId) async {
    specApplyCalls.add(changeId);
    if (specApplyError case final e?) throw e;
    final c = _pending.remove(changeId);
    if (c == null) throw const ServerException(409, 'change_unknown', null, 'change_unknown');
    if (!fakeClock().isBefore(c.proposal.expiresAt!)) {
      throw const ServerException(410, 'change_expired', null, 'change_expired');
    }
    if (c.proposal.baseVersion != fakeSpec.version) throw const ServerException(409, 'stale_version');
    final j = c.spec.toJson()..['version'] = fakeSpec.version + 1;
    fakeSpec = SettingsSpec.fromJson(j);
    fakeSources = c.sources;
    return specGet();
  }

  SpecProposal _stage(int base, List<SpecDiffEntry> diff, SettingsSpec spec, List<KnowledgeSource> sources) {
    final p = SpecProposal(
        changeId: 'chg-${++_changeSeq}',
        baseVersion: base,
        diff: diff,
        readback: 'This changes ${diff.length} setting${diff.length == 1 ? '' : 's'}.',
        expiresAt: fakeClock().add(const Duration(minutes: 5)));
    _pending[p.changeId] = (proposal: p, spec: spec, sources: sources);
    return p;
  }

  static Map<String, dynamic> _merge(Map<String, dynamic> a, Map<String, dynamic> b) => {
        ...a,
        for (final e in b.entries)
          e.key: e.value is Map<String, dynamic> && a[e.key] is Map<String, dynamic>
              ? _merge(a[e.key] as Map<String, dynamic>, e.value as Map<String, dynamic>)
              : e.value,
      };

  static List<SpecDiffEntry> _diff(Map<String, dynamic> a, Map<String, dynamic> b, [String pre = '']) => [
        for (final k in b.keys)
          if (k != 'version')
            if (b[k] is Map<String, dynamic>)
              ..._diff(a[k] as Map<String, dynamic>, b[k] as Map<String, dynamic>, '$pre$k.')
            else if (a[k] != b[k])
              SpecDiffEntry('$pre$k', a[k], b[k]),
      ];

  @override
  Future<LogParseResult> parseLog(String kind, String text,
      {Map<String, String> prefs = const {}, String? date}) async {
    calls.add('/log/parse');
    logParseCalls.add((kind: kind, text: text, prefs: prefs, date: date));
    if (logParseGate case final g?) await g.future;
    final e = logParseError;
    if (e != null) throw e;
    return logParseFor?.call(kind, text) ?? logParseResult;
  }

  Stream<ReplyStreamEvent> _streamEvents(CancelToken? cancel) async* {
    final e = replyStreamError;
    if (e != null) throw e;
    final events = replyStreamEvents ??
        [
          ReplyStreamDone(
              text: replyResult.text,
              personalityId: replyResult.personalityId,
              safety: replyResult.safety ?? 'passed'),
        ];
    for (final ev in events) {
      if (cancel?.isCancelled ?? false) throw const ServerException(0, 'cancelled');
      yield ev;
    }
  }
}

/// [s], ended with a `cancelled` [ServerException] the moment [cancel]
/// fires; the read of [s] is cancelled then.
Stream<T> _untilCancelled<T>(Stream<T> s, CancelToken? cancel) {
  if (cancel == null) return s;
  final out = StreamController<T>(sync: true);
  StreamSubscription<T>? sub;
  out
    ..onListen = () {
      sub = s.listen(out.add, onError: out.addError, onDone: out.close);
      cancel.onCancel(() {
        unawaited(sub?.cancel());
        if (out.isClosed) return;
        out.addError(const ServerException(0, 'cancelled'));
        unawaited(out.close());
      });
    }
    ..onPause = (() => sub?.pause())
    ..onResume = (() => sub?.resume())
    ..onCancel = (() => sub?.cancel());
  return out.stream;
}

/// Usable device token, or null when [raw] is empty or holds whitespace
/// (a header value must be a single token, see server/src/auth.js).
String? _usableToken(String raw) {
  final t = raw.trim();
  return t.isEmpty || t.contains(RegExp(r'\s')) ? null : t;
}

/// JSON over HTTP with dart:io (no extra package). [deviceToken] is
/// required: every request carries `Authorization: Bearer <deviceToken>`
/// (server/src/auth.js). An empty or whitespace token fails an assert in
/// debug builds; in release it makes no request and fails with
/// [ServerException] code `no_device_token`. The app builds this port
/// through [serverPortFor]. The token is never logged or put in an exception.
class HttpServerPort implements ServerPort {
  HttpServerPort(String baseUrl,
      {required String deviceToken, HttpClient? client, this.timeout = const Duration(seconds: 60)})
      : assert(_usableToken(deviceToken) != null, 'HttpServerPort needs a non-empty device token'),
        _base = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _token = _usableToken(deviceToken),
        _client = client ?? HttpClient();

  final String _base;
  final String? _token;
  final HttpClient _client;
  final Duration timeout;

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
          {CancelToken? cancel}) =>
      _send('POST', path, body, cancel: cancel);

  /// One JSON request. [body] null sends none (GET). A non-2xx answer fails
  /// with [ServerException] (error, detail and code fields only); [onError]
  /// may turn the decoded error body into its own exception first.
  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic>? body,
      {CancelToken? cancel, Object? Function(int status, Map<String, dynamic> body)? onError}) async {
    const cancelled = ServerException(0, 'cancelled');
    final token = _token;
    if (token == null) throw const ServerException(0, 'no_device_token');
    if (cancel?.isCancelled ?? false) throw cancelled;
    final uri = Uri.parse('$_base$path');
    final req = await (method == 'GET' ? _client.getUrl(uri) : _client.postUrl(uri)).timeout(timeout);
    if (cancel?.isCancelled ?? false) {
      req.abort();
      throw cancelled;
    }
    cancel?.onCancel(() => req.abort(cancelled));
    if (body != null) req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) req.write(jsonEncode(body));
    final HttpClientResponse res;
    final String text;
    try {
      res = await req.close().timeout(timeout);
      text = await res.transform(utf8.decoder).join().timeout(timeout);
    } catch (_) {
      if (cancel?.isCancelled ?? false) throw cancelled;
      rethrow;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    final map = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final custom = onError?.call(res.statusCode, map);
      if (custom != null) throw custom;
      final code = map['code'];
      throw ServerException(res.statusCode, map['error'] as String? ?? 'http_error', map['detail'] as String?,
          code is String ? code : null);
    }
    if (decoded is! Map<String, dynamic>) {
      throw ServerException(res.statusCode, 'invalid_response');
    }
    return map;
  }

  @override
  Future<RouteResult> route(String transcript) async =>
      RouteResult.fromJson(await _post('/router', {'transcript': transcript}));

  @override
  Future<TurnPlan> turn({
    required String transcript,
    Map<String, dynamic> context = const {},
    PhoneContext? phone,
    CancelToken? cancel,
  }) async =>
      TurnPlan.fromJson(await _post(
          '/turn', {'transcript': transcript, 'context': context, ...?phone?.toJson()},
          cancel: cancel));

  @override
  Future<DigestResult> digest({
    required String personalityId,
    required List<Finding> findings,
    String? skillPackId,
    CouncilContext? context,
    bool council = true,
  }) async {
    final ctx = context?.toJson();
    return DigestResult.fromJson(await _post('/digest', {
      'personality_id': personalityId,
      'findings': [for (final f in findings) f.toJson()],
      'skill_pack_id': ?skillPackId,
      if (ctx != null && ctx.isNotEmpty) 'context': ctx,
      if (!council) 'council': false,
    }));
  }

  @override
  Future<CouncilResult> council({
    required String question,
    CouncilContext? context,
    String purpose = 'chat',
  }) async {
    final ctx = context?.toJson();
    final r = CouncilResult.fromJson(await _post('/council', {
      'question': question,
      if (ctx != null && ctx.isNotEmpty) 'context': ctx,
      'purpose': purpose,
    }));
    if (r.synthesis.isEmpty) throw const ServerException(200, 'invalid_response');
    return r;
  }

  @override
  Future<AnalysisResult> analysis21d(Map<String, dynamic> body) async =>
      AnalysisResult.fromJson(await _post('/analysis/21d', body));

  @override
  Future<AssistantReply> assistantMessage(String text, {String? context}) async {
    final c = context?.trim();
    final r = AssistantReply.fromJson(await _post('/assistant/message', {
      'text': text,
      if (c != null && c.isNotEmpty) 'context': c.length <= 4000 ? c : c.substring(c.length - 4000),
    }));
    if (r.text.isEmpty) throw const ServerException(200, 'invalid_response');
    return r;
  }

  @override
  Future<ActionProposal> assistantPropose(String request) async {
    final j = await _send('POST', '/assistant/action/propose', {'request': request}, onError: (status, b) {
      if (status != 422 || b['error'] != 'action_refused') return null;
      final code = b['code'], text = b['text'];
      return ActionRefused(code is String ? code : 'refused', referral: text is String ? text : null);
    });
    final p = ActionProposal.fromJson(j);
    if (p == null) throw const ServerException(200, 'invalid_response');
    return p;
  }

  @override
  Future<ActionOutcome> assistantConfirm(String actionId) async => ActionOutcome.fromJson(
      await _post('/assistant/action/confirm', {'action_id': actionId, 'confirm_phrase_heard': true}));

  @override
  Future<InboxBatch> assistantInbox({int limit = 20}) async =>
      InboxBatch.fromJson(await _send('GET', '/assistant/inbox?limit=$limit', null));

  @override
  Future<ReplyResult> reply({
    required Map<String, dynamic> plan,
    required String transcript,
    PhoneContext? phone,
    CancelToken? cancel,
  }) async =>
      ReplyResult.fromJson(await _post(
          '/reply', {'plan': plan, 'transcript': transcript, ...?phone?.toJson()},
          cancel: cancel));

  @override
  Stream<ReplyStreamEvent> replyStream({
    required Map<String, dynamic> plan,
    required String transcript,
    PhoneContext? phone,
    CancelToken? cancel,
  }) async* {
    const cancelled = ServerException(0, 'cancelled');
    const dropped = ServerException(0, 'stream_dropped');
    final token = _token;
    if (token == null) throw const ServerException(0, 'no_device_token');
    if (cancel?.isCancelled ?? false) throw cancelled;
    final req = await _client.postUrl(Uri.parse('$_base/reply/stream')).timeout(timeout);
    if (cancel?.isCancelled ?? false) {
      req.abort();
      throw cancelled;
    }
    cancel?.onCancel(() => req.abort(cancelled));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.write(jsonEncode({'plan': plan, 'transcript': transcript, ...?phone?.toJson()}));
    final HttpClientResponse res;
    try {
      res = await req.close().timeout(timeout);
    } catch (_) {
      if (cancel?.isCancelled ?? false) throw cancelled;
      rethrow;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Object? j;
      try {
        j = jsonDecode(await res.transform(utf8.decoder).join().timeout(timeout));
      } catch (_) {
        j = null;
      }
      final map = j is Map<String, dynamic> ? j : const <String, dynamic>{};
      throw ServerException(
          res.statusCode, map['error'] as String? ?? 'http_error', map['detail'] as String?);
    }
    final parser = SseParser();
    // Each chunk must arrive within [timeout] (idle limit, not a total).
    // abort() does not end a response already being read, so a cancel also
    // cancels the read itself.
    final text = _untilCancelled(res.transform(utf8.decoder).timeout(timeout), cancel);
    try {
      await for (final chunk in text) {
        for (final e in parser.add(chunk)) {
          final ev = ReplyStreamEvent.fromSse(e);
          if (ev == null) continue;
          yield ev;
          if (ev is! ReplySentence) return;
        }
      }
      for (final e in parser.close()) {
        final ev = ReplyStreamEvent.fromSse(e);
        if (ev == null) continue;
        yield ev;
        if (ev is! ReplySentence) return;
      }
    } on TimeoutException {
      if (cancel?.isCancelled ?? false) throw cancelled;
      rethrow;
    } catch (_) {
      if (cancel?.isCancelled ?? false) throw cancelled;
      throw dropped;
    }
    if (cancel?.isCancelled ?? false) throw cancelled;
    throw dropped; // Ended without done or error.
  }

  @override
  Future<void> memoryWrite(MemoryNote note) => _post('/memory/write', note.toJson());

  @override
  Future<String> sessionSummary({
    required List<SessionTurn> turns,
    required DateTime startedAt,
    required DateTime endedAt,
  }) async {
    final j = await _post('/session/summary', {
      'turns': [for (final t in turns) t.toJson()],
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt.toUtc().toIso8601String(),
    });
    final s = j['summary'];
    if (s is! String || s.trim().isEmpty) throw const ServerException(200, 'invalid_response');
    return s.trim();
  }

  @override
  Future<void> assistantMemoryWrite(MemoryNote note) => _post('/assistant/memory/write', note.toJson());

  @override
  Future<List<RecalledMemory>> assistantMemoryRecall(String query, {int k = 5}) async {
    final j = await _post('/assistant/memory/recall', {'query': query, 'k': k});
    final list = j['items'] ?? j['memories'];
    if (list is! List) return const [];
    return [for (final m in list) ?RecalledMemory.fromJson(m)].take(k).toList();
  }

  @override
  Future<LogParseResult> parseLog(String kind, String text,
      {Map<String, String> prefs = const {}, String? date}) async {
    final Map<String, dynamic> j;
    try {
      j = await _post('/log/parse', {'kind': kind, 'text': text, 'prefs': prefs, 'date': ?date});
    } on ServerException catch (e) {
      // 422 is a rejected model answer with a fixed code, not a failure.
      if (e.status == 422 && e.code != null) return LogParseResult.rejected(e.code!);
      rethrow;
    }
    return LogParseResult.fromJson(j) ?? (throw const ServerException(200, 'invalid_response'));
  }

  @override
  Future<SpecState> specGet() async => SpecState.fromJson(await _send('GET', '/spec', null));

  @override
  Future<List<KnowledgeSource>> knowledgeSources() async {
    final l = (await _send('GET', '/knowledge/sources', null))['sources'];
    return l is List ? [for (final s in l) ?KnowledgeSource.fromJson(s)] : const [];
  }

  Future<SpecProposal> _propose(String path, Map<String, dynamic> body) async {
    final j = await _send('POST', path, body, onError: (status, b) => status == 422 && b['refused'] is List ? SpecRefused.fromJson(b) : null);
    return SpecProposal.fromJson(j) ?? (throw const ServerException(200, 'invalid_response'));
  }

  @override
  Future<SpecProposal> specPropose({required int baseVersion, Map<String, dynamic>? patch, String? request}) =>
      _propose('/spec/propose', {'base_version': baseVersion, 'spec_patch': ?patch, 'request': ?request});

  @override
  Future<SpecState> specApply(String changeId) async =>
      SpecState.fromJson(await _post('/spec/apply', {'change_id': changeId}));

  @override
  Future<SpecProposal> knowledgeAdd({required int baseVersion, required String title, required String text, String bank = 'reading'}) =>
      _propose('/knowledge/add', {
          'base_version': baseVersion,
          'source': {'title': title, 'text': text, 'origin': 'you', 'date': DateTime.now().toUtc().toIso8601String().substring(0, 10), 'bank': bank},
        });

  @override
  Future<SpecProposal> knowledgeRemove({required int baseVersion, required String sourceId}) =>
      _propose('/knowledge/remove', {'base_version': baseVersion, 'source_id': sourceId});

  void close() => _client.close(force: true);
}

/// Empty [baseUrl] (the default) means the offline fake. A URL without a
/// usable [deviceToken] also means the fake, so the server is never called
/// unauthenticated; that case logs the fixed code `server: no_device_token`
/// (the token itself is never logged).
ServerPort serverPortFor(String baseUrl,
    {String deviceToken = '', void Function(String)? log}) {
  final url = baseUrl.trim();
  if (url.isEmpty) return FakeServerPort();
  if (_usableToken(deviceToken) == null) {
    (log ?? debugPrint)('server: no_device_token');
    return FakeServerPort();
  }
  return HttpServerPort(url, deviceToken: deviceToken);
}
