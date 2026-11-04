/// Talking to the connected assistant by voice (assistant_intent.dart):
/// "ask my assistant ..." goes to POST /assistant/message and the answer is
/// spoken; "tell my coach bot ..." or "ask my assistant to ..." goes to POST
/// /assistant/action/propose and then to the spoken approval flow. A
/// proposal that comes back with a message answer goes there too.
///
/// Logs carry fixed codes only, never what was asked or answered.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../voice/assistant_intent.dart';
import 'approval_flow.dart';
import 'aside.dart';
import 'server_port.dart';

abstract final class AssistantPrompt {
  static const notLinked = 'No assistant is connected to this phone yet.';
  static const asking = 'Asking your assistant.';
  static const checking = 'Checking with your assistant.';
  static const timeout = 'Your assistant did not answer in time.';
  static const unavailable = 'I could not reach your assistant.';
  static const refused = 'Your assistant cannot do that.';
  static const notAllowed = 'I cannot send that.';
}

class AssistantBridge {
  AssistantBridge({
    required this.server,
    required this.approval,
    required this.speak,
    required this.linked,
    String? Function()? context,
    bool Function()? quiet,
    this.onExchange,
    AsideLog? log,
  })  : _context = context ?? (() => null),
        _quiet = quiet ?? (() => true),
        _log = log ?? debugPrint;

  final ServerPort server;
  final ApprovalFlow approval;
  final AsideSpeak speak;

  /// False when no assistant link is configured (offline build).
  final bool Function() linked;

  /// The user's question and the spoken answer (short-term memory).
  final void Function(String text, String answer)? onExchange;
  final String? Function() _context;
  final bool Function() _quiet;
  final AsideLog _log;

  bool _running = false;
  Future<void> _queue = Future.value();

  bool get busy => _running;
  Future<void> get settled => _queue;

  /// Takes an assistant intent; anything else is left alone.
  bool claim(String text) {
    final intent = parseAssistantIntent(text);
    if (intent == null) return false;
    _queue = _queue.then((_) => _run(intent));
    return true;
  }

  Future<void> _run(AssistantIntent intent) async {
    if (!linked()) {
      _log('assistant: not_linked');
      await speak(AssistantPrompt.notLinked);
      return;
    }
    _running = true;
    try {
      switch (intent.kind) {
        case AssistantIntentKind.message:
          await _message(intent.text);
        case AssistantIntentKind.action:
          await _propose(intent.text);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _message(String text) async {
    await speak(AssistantPrompt.asking);
    final AssistantReply r;
    try {
      r = await server.assistantMessage(text, context: _context());
    } catch (e) {
      return _failed('message', e);
    }
    if (!await waitForQuiet(_quiet)) return _log('assistant: answer_dropped code=busy');
    _log('assistant: answered');
    final heard = await speak(r.text);
    if (heard && r.safety != 'replaced' && r.safety != 'crisis') onExchange?.call(text, r.text);
    final p = r.proposal;
    if (heard && p != null) await approval.start(p);
  }

  Future<void> _propose(String request) async {
    await speak(AssistantPrompt.checking);
    final ActionProposal p;
    try {
      p = await server.assistantPropose(request);
    } on ActionRefused catch (e) {
      _log('assistant: action_refused code=${e.code}');
      final referral = e.referral;
      await speak(e.code == 'crisis' && referral != null && referral.trim().isNotEmpty
          ? referral
          : AssistantPrompt.notAllowed);
      return;
    } catch (e) {
      return _failed('propose', e);
    }
    if (!await waitForQuiet(_quiet)) return _log('assistant: proposal_dropped code=busy');
    await approval.start(p);
  }

  Future<void> _failed(String what, Object e) async {
    final code = asideCode(e);
    _log('assistant: ${what}_failed code=$code');
    await speak(switch (code) {
      'assistant_not_linked' => AssistantPrompt.notLinked,
      'assistant_timeout' || 'timeout' => AssistantPrompt.timeout,
      'assistant_refused' => AssistantPrompt.refused,
      _ => AssistantPrompt.unavailable,
    });
  }
}
