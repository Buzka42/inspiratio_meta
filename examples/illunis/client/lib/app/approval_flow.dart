/// Spoken approval for an assistant action (docs/DESIGN.md
/// section 5.4, integrations/hermes/CONTRACT.md "Approval flow"). Illunis reads the
/// Worker's readback aloud and listens. Only an explicit "yes", "do it" or
/// "go ahead" (confirm_phrase.dart) sends POST /assistant/action/confirm
/// `{action_id, confirm_phrase_heard: true}`. Anything else, a readback the
/// user interrupted, or [ApprovalFlow.silence] without an answer cancels.
/// Nothing is ever confirmed without a heard phrase.
///
/// Logs carry fixed codes only, never the readback or the answer.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../voice/confirm_phrase.dart';
import 'aside.dart';
import 'server_port.dart';

abstract final class ApprovalPrompt {
  static const question = 'Should I go ahead?';
  static const cancelled = 'Cancelled. Nothing was sent.';
  static const done = 'Done.';
  static const queued = 'Your assistant has it and will send it shortly.';
  static const failed = 'Your assistant could not do that.';
  static const expired = 'That request expired, so nothing was sent.';
  static const unknownResult = 'I could not reach your assistant, so I cannot tell whether it was sent.';
}

enum ApprovalState { idle, reading, listening, confirming }

/// "`readback`. Should I go ahead?" with one full stop between them.
String approvalPrompt(String readback) {
  final r = readback.trim();
  final end = r.isEmpty || '.!?'.contains(r[r.length - 1]) ? '' : '.';
  return '$r$end ${ApprovalPrompt.question}';
}

class ApprovalFlow {
  ApprovalFlow({
    required this.server,
    required this.speak,
    this.listen,
    OneShotTimer? timer,
    this.silence = const Duration(seconds: 8),
    AsideLog? log,
  })  : _timer = timer ?? realTimer,
        _log = log ?? debugPrint;

  final ServerPort server;
  final AsideSpeak speak;
  final AsideListen? listen;

  /// No answer within this time after the readback cancels.
  final Duration silence;
  final OneShotTimer _timer;
  final AsideLog _log;

  ApprovalState _state = ApprovalState.idle;
  ActionProposal? _pending;
  Timer? _silenceTimer;
  int _seq = 0;
  Future<void> _queue = Future.value();

  ApprovalState get state => _state;
  bool get busy => _state != ApprovalState.idle;
  Future<void> get settled => _queue;

  /// Reads [p] back and waits for the answer. A proposal already waiting is
  /// dropped first (it is never confirmed).
  Future<void> start(ActionProposal p) {
    if (busy) _reset('replaced');
    final id = ++_seq;
    _pending = p;
    _state = ApprovalState.reading;
    _log('approval: readback');
    _queue = _queue.then((_) async {
      final heard = await speak(approvalPrompt(p.readback));
      if (_seq != id || _state != ApprovalState.reading) return;
      if (!heard) {
        // The user did not hear it all: never ask for a yes to half a readback.
        _reset('interrupted');
        return;
      }
      _state = ApprovalState.listening;
      listen?.call();
      _silenceTimer = _timer(silence, () {
        if (_seq != id || _state != ApprovalState.listening) return;
        _reset('timeout');
        _queue = _queue.then((_) => speak(ApprovalPrompt.cancelled));
      });
    });
    return _queue;
  }

  /// Takes every transcript while a proposal is open.
  bool claim(String text) {
    switch (_state) {
      case ApprovalState.idle:
      case ApprovalState.confirming:
        return false;
      case ApprovalState.reading:
        // Spoke over the readback: cancel, never confirm.
        _reset('spoke_over');
        _queue = _queue.then((_) => speak(ApprovalPrompt.cancelled));
        return true;
      case ApprovalState.listening:
        final p = _pending!;
        _silenceTimer?.cancel();
        if (!isConfirmPhrase(text)) {
          _reset('rejected');
          _queue = _queue.then((_) => speak(ApprovalPrompt.cancelled));
          return true;
        }
        _state = ApprovalState.confirming;
        _queue = _queue.then((_) => _confirm(p));
        return true;
    }
  }

  Future<void> _confirm(ActionProposal p) async {
    String say;
    try {
      final o = await server.assistantConfirm(p.actionId);
      _log('approval: confirmed status=${o.status}');
      say = switch (o.status) {
        'done' => ApprovalPrompt.done,
        'queued' => ApprovalPrompt.queued,
        _ => ApprovalPrompt.failed,
      };
    } on ServerException catch (e) {
      final expired = e.status == 410 || e.status == 404;
      _log('approval: confirm_failed code=${expired ? 'expired' : asideCode(e)}');
      say = expired ? ApprovalPrompt.expired : ApprovalPrompt.unknownResult;
    } catch (e) {
      _log('approval: confirm_failed code=${asideCode(e)}');
      say = ApprovalPrompt.unknownResult;
    }
    _reset(null);
    await speak(say);
  }

  void _reset(String? why) {
    if (why != null) _log('approval: cancelled code=$why');
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _pending = null;
    _state = ApprovalState.idle;
    _seq++;
  }

  void dispose() => _reset(null);
}
