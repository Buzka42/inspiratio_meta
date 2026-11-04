/// App state in plain Dart: graphic mode, voice session, fog, caption.
/// Executes the commands the pure voice reducer returns.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/fog_settings.dart';
import '../core/mode_controller.dart';
import '../memory/local_memory_backend.dart';
import '../memory/memory_backend.dart';
import '../memory/memory_note.dart';
import '../memory/phone_context.dart';
import '../memory/short_term_memory.dart';
import '../output/speech_output.dart';
import '../output/tts_engine.dart';
import '../voice/voice_session.dart';
import 'memory_writer.dart';
import 'persistence.dart';
import 'server_port.dart';
import 'tts_port.dart';

/// Spoken when the reply (or the route) fails. Fixed, short, no payload.
const replyFallbackText = 'Sorry, I cannot answer right now.';

typedef ControllerLog = void Function(String message);

/// A transcript that was not a mode command and needs a reply.
class TurnRequest {
  const TurnRequest(this.id, this.text);
  final int id;
  final String text;
}

enum UtteranceOutcome { modeChanged, turnRequested, setupHandled, ignored }

/// A turn that completed with a real answer (see [AppController.routeTurn]).
/// [councilSuggested] is the reply model's flag, false when the server sent
/// none.
class AnsweredTurn {
  const AnsweredTurn({required this.transcript, required this.answer, this.councilSuggested = false});
  final String transcript;
  final String answer;
  final bool councilSuggested;
}

class AppController {
  AppController({
    required this.fog,
    required this.server,
    required this.tts,
    ModeController? modes,
    SpeechOutput? speech,
    ControllerLog? log,
    this.streamReplies = true,
    MemoryWriter? memory,
    this.shortTerm,
    this.recallK = defaultRecallK,
    this.recallTimeout = const Duration(milliseconds: 1500),
  })  : modes = modes ?? ModeController(),
        speech = speech ?? SpeechOutput(TtsPortEngine(tts)),
        _log = log ?? debugPrint {
    this.memory = memory ?? MemoryWriter(LocalMemoryBackend(InMemoryStateStore()), log: _log);
    this.modes.addListener(_onMode);
  }

  final ModeController modes;
  final FogSettings fog;
  final ServerPort server;
  final TtsPort tts;

  /// Reply, referral and (when shared with [MorningFlow]) digest speech:
  /// chunked and cancellable. Defaults to an adapter over [tts].
  final SpeechOutput speech;
  final ControllerLog _log;

  /// True (the default): replies come from POST /reply/stream and each
  /// sentence is spoken as it arrives. False: one POST /reply, then speech.
  final bool streamReplies;

  /// Stores one memory note after each completed turn in the selected
  /// long-term backend; the same backend is asked for the top [recallK]
  /// notes before each turn. Defaults to an in-memory phone store.
  late final MemoryWriter memory;

  /// The conversation so far plus recent session summaries, sent with /turn
  /// and /reply. Null sends none.
  final ShortTermMemory? shortTerm;
  final int recallK;

  /// Recall that takes longer is skipped for this turn (logged as a code).
  final Duration recallTimeout;

  VoiceState _voice = VoiceState.idle;
  String? _caption;
  int _turnSeq = 0;

  /// Id of the turn whose reply is still wanted; null after cancel.
  int? _activeTurn;
  TurnPlan? _lastPlan;

  /// Covers the whole turn: POST /turn and then POST /reply.
  CancelToken? _pendingReply;

  /// Turn whose reply [speech] is playing, if any.
  int? _speechTurn;

  /// True while a playback event is echoed into the reducer as ReplyChunk,
  /// so its Speak command only updates the caption (already playing).
  bool _echoing = false;

  final _listeners = <void Function()>[];
  final _turns = StreamController<TurnRequest>.broadcast(sync: true);
  final _listen = StreamController<void>.broadcast(sync: true);

  GraphicMode get mode => modes.mode;
  VoiceState get voice => _voice;
  bool get fogEnabled => fog.enabled;

  /// Last text Illunis spoke; the caption overlay shows it.
  String? get caption => _caption;
  /// True when nothing is said or heard: no turn, no listening, no speech.
  /// The assistant inbox speaks only then.
  bool get idle => _voice == VoiceState.idle && _activeTurn == null && !speech.isSpeaking;

  /// Runs after a turn completed with a real answer and its speech ended
  /// (the council offer). Not called on crisis, fallback, replaced or cancel.
  void Function(AnsweredTurn turn)? afterAnswer;

  /// Plan from the last POST /turn that was not cancelled.
  TurnPlan? get lastPlan => _lastPlan;
  Stream<TurnRequest> get turnRequests => _turns.stream;

  /// Fires on every StartListening command; the input pipeline opens a
  /// speech-to-text session on it.
  Stream<void> get listenRequests => _listen.stream;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void _onMode(GraphicMode _) => _notify();

  Future<void> load() async {
    await fog.load();
    _notify();
  }

  Future<void> setFog(bool on) async {
    await fog.setEnabled(on);
    _notify();
  }

  /// Voice setup (VoiceSetup.claim): returns true when it takes the
  /// transcript (an interview answer or "change my alarm to ..."). Checked
  /// before mode commands. Null leaves every transcript to modes and turns.
  bool Function(String text)? setupHook;

  /// Fires when a listening turn ends with no speech (an empty final).
  void Function()? onSilence;

  /// Setup first, then mode commands; anything else becomes a [TurnRequest].
  UtteranceOutcome handleUtterance(String text) {
    final t = text.trim();
    if (t.isEmpty) return UtteranceOutcome.ignored;
    if (setupHook?.call(t) ?? false) return UtteranceOutcome.setupHandled;
    if (modes.handleUtterance(t)) return UtteranceOutcome.modeChanged;
    final req = TurnRequest(++_turnSeq, t);
    _activeTurn = req.id;
    _turns.add(req);
    return UtteranceOutcome.turnRequested;
  }

  /// Feeds an event through the voice reducer and runs its commands.
  /// Speech the user starts while non-turn speech (the morning digest) plays
  /// cancels it, then opens listening. The reducer has no digest state, so
  /// this is handled here.
  void dispatch(VoiceEvent event) {
    if (_interruptsDigest(event)) {
      speech.cancel();
      if (_voice == VoiceState.idle && event is! WakeWordHeard) {
        event = const WakeWordHeard();
      }
    }
    final silent = event is UserSpeechEnded &&
        event.transcript.trim().isEmpty &&
        _voice == VoiceState.listening;
    final (next, commands) = reduce(_voice, event);
    final changed = next != _voice;
    _voice = next;
    for (final c in commands) {
      _run(c);
    }
    if (changed) _notify();
    if (silent) onSilence?.call();
  }

  bool _interruptsDigest(VoiceEvent e) =>
      (e is WakeWordHeard || e is BargeIn || e is UserSpeechStarted) &&
      _speechTurn == null &&
      speech.isSpeaking;

  void _run(VoiceCommand c) {
    switch (c) {
      case StartListening():
        _listen.add(null);
      case StopPlayback():
        unawaited(tts.stop());
        speech.cancel();
      case CancelGeneration():
        _activeTurn = null;
        _pendingReply?.cancel();
        _pendingReply = null;
        if (_speechTurn != null) speech.cancel();
      case SubmitTranscript(:final transcript):
        if (handleUtterance(transcript) != UtteranceOutcome.turnRequested) {
          dispatch(const ReplyDone());
        }
      case Speak(:final text):
        if (_echoing) {
          _caption = text;
          _notify();
        } else {
          say(text);
        }
    }
  }

  /// Shows [text] as the caption without speaking it (council source titles).
  void showCaption(String text) {
    _caption = text;
    _notify();
  }

  /// Speaks [text] through [speech] outside a voice turn (council answers,
  /// assistant readbacks and inbox items), showing each sentence as the
  /// caption when it starts. Like the digest, a wake word or barge-in
  /// cancels it. True when every sentence played.
  Future<bool> speakAside(String text) async {
    if (text.trim().isEmpty) return true;
    PlaybackEvent? last;
    await for (final e in speech.speak(text)) {
      last = e;
      if (e is PlaybackStarted) showCaption(e.text);
      if (e is PlaybackFailed) _log('speech: aside_failed code=${e.code}');
    }
    return last is PlaybackFinished;
  }

  /// Shows [text] as the caption and speaks it.
  void say(String text) {
    _caption = text;
    unawaited(tts.speak(text));
    _notify();
  }

  /// Default turn handler. POST /turn with the transcript; a crisis speaks
  /// the server's fixed referral and never reaches /reply. Otherwise POST
  /// /reply/stream (see [_streamTurn]; POST /reply when [streamReplies] is
  /// false or the stream route is missing) with the returned plan and the
  /// transcript, and speaks the reply sentence by sentence (one ReplyChunk
  /// per sentence, ReplyDone at the end). A failure speaks
  /// [replyFallbackText]. One cancel token covers both requests, so a
  /// barge-in during either drops the turn.
  ///
  /// A turn that completes with a real answer (not crisis, not safety
  /// replaced, not the fallback, not barged in) then hands the transcript and
  /// answer to [memory], unawaited: the write never delays or breaks speech.
  Future<void> routeTurn(TurnRequest req) async {
    if (_activeTurn != req.id) return; // Cancelled before it started.
    final token = _pendingReply = CancelToken();
    try {
      unawaited(shortTerm?.rollOverIfStale());
      final (answer, suggested) = await _runTurn(req, token);
      if (answer != null && !token.isCancelled) {
        unawaited(memory.afterTurn(transcript: req.text, answer: answer));
        unawaited(shortTerm?.addExchange(user: req.text, assistant: answer));
        afterAnswer?.call(AnsweredTurn(transcript: req.text, answer: answer, councilSuggested: suggested));
      }
    } finally {
      if (identical(_pendingReply, token)) _pendingReply = null;
    }
  }

  /// The short-term context and the top recalled notes for [transcript], or
  /// null when both are empty (the request bodies then stay as before).
  /// A failed or slow recall sends no notes and logs the code only.
  Future<PhoneContext?> _phoneContext(String transcript) async {
    final st = shortTerm?.context() ?? const ShortTermContext();
    var notes = const <RecalledMemory>[];
    if (recallK > 0) {
      try {
        notes = await memory.backend.recall(transcript, k: recallK).timeout(recallTimeout);
      } on MemoryUnavailable catch (e) {
        _log('memory: recall_failed code=${e.code}');
      } catch (e) {
        _log('memory: recall_failed code=${_code(e)}');
      }
    }
    if (st.isEmpty && notes.isEmpty) return null;
    return PhoneContext(shortTerm: st, memories: notes);
  }

  /// The turn itself; returns the answer when the turn completed with one,
  /// and the reply's council flag.
  Future<(String?, bool)> _runTurn(TurnRequest req, CancelToken token) async {
    final phone = await _phoneContext(req.text);
    if (_dropped(req.id, token)) return (null, false);
    final plan = await _call('turn_failed', req.id, token,
        () => server.turn(transcript: req.text, context: const {}, phone: phone, cancel: token));
    if (_dropped(req.id, token)) return (null, false);
    _lastPlan = plan;
    if (plan == null) {
      await _speakTurn(req.id, replyFallbackText);
      return (null, false);
    }
    if (plan.crisis) {
      final referral = plan.response;
      if (referral != null && referral.trim().isNotEmpty) {
        await _speakTurn(req.id, referral);
        return (null, false);
      }
      _log('reply: crisis_without_referral');
      _endTurn(req.id);
      return (null, false);
    }

    if (streamReplies) {
      final streamed = await _streamTurn(req, plan, phone, token);
      if (streamed.handled) return (streamed.answer, streamed.suggested);
    }
    if (_dropped(req.id, token)) return (null, false);
    final reply = await _call('failed', req.id, token,
        () => server.reply(plan: plan.toReplyPlan(), transcript: req.text, phone: phone, cancel: token));
    if (_dropped(req.id, token)) return (null, false);
    String? answer;
    if (reply != null && reply.text.trim().isEmpty) {
      _log('reply: failed code=empty_reply');
    } else if (reply != null && !_replaced(reply.safety)) {
      answer = reply.text;
    }
    await _speakTurn(req.id, reply == null || reply.text.trim().isEmpty ? replyFallbackText : reply.text);
    return (answer, reply?.councilSuggested ?? false);
  }

  /// The server's safety field says the reply was swapped for the referral.
  static bool _replaced(Object? safety) => safety == 'replaced';

  bool _dropped(int id, CancelToken token) => _activeTurn != id || token.isCancelled;

  /// Runs one request; a failure logs `reply: <what> code=...` (unless the
  /// turn was cancelled) and yields null.
  Future<T?> _call<T>(String what, int id, CancelToken token, Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      if (!_dropped(id, token)) _log('reply: $what code=${_code(e)}');
      return null;
    }
  }

  /// POST /reply/stream: each sentence is queued into [speech] as it arrives
  /// and plays in order. On `done` its text is queued last; on safety
  /// "replaced" every sentence not yet started is dropped and only the
  /// referral follows. An error event, a failed request or a dropped stream
  /// stops speech and speaks [replyFallbackText], logging the code only.
  /// A cancel of [token] (barge-in) stops the read at once; the existing
  /// cancel path stops the speech. Returns false only when the route is
  /// missing (404 before any event: server not deployed yet), so the caller
  /// can use POST /reply instead. [answer] is the spoken reply when the
  /// stream completed normally (null on failure, replaced or cancel).
  Future<({bool handled, String? answer, bool suggested})> _streamTurn(
      TurnRequest req, TurnPlan plan, PhoneContext? phone, CancelToken token) async {
    final id = req.id;
    SpeechFeed? feed;
    Future<void>? playing;
    void queue(String text) {
      if (feed == null) {
        _speechTurn = id;
        feed = speech.feed();
        playing = _playTurn(id, feed!.events);
      }
      feed!.add(text);
    }

    var spoke = false;
    final sentences = <String>[];
    String? answer;
    ReplyStreamDone? done;
    final ended = Completer<Object?>(); // null, or the failure
    late final StreamSubscription<ReplyStreamEvent> sub;
    void finish(Object? failure) {
      if (ended.isCompleted) return;
      ended.complete(failure);
      unawaited(sub.cancel());
    }

    sub = server
        .replyStream(plan: plan.toReplyPlan(), transcript: req.text, phone: phone, cancel: token)
        .listen((e) {
      if (ended.isCompleted || _dropped(id, token)) return;
      switch (e) {
        case ReplySentence(:final text):
          if (text.trim().isEmpty) return;
          spoke = true;
          sentences.add(text);
          queue(text);
        case ReplyStreamDone():
          done = e;
          finish(null);
        case ReplyStreamError(:final error):
          finish(ServerException(0, error));
      }
    },
            onError: (Object e) => finish(e),
            onDone: () => finish(const ServerException(0, 'stream_dropped')),
            cancelOnError: true);
    token.onCancel(() => finish(const ServerException(0, 'cancelled')));

    final failure = await ended.future;
    if (_dropped(id, token)) {
      await playing;
      return (handled: true, answer: null, suggested: false);
    }
    final last = done;
    if (failure != null) {
      if (!spoke && failure is ServerException && failure.status == 404) {
        _log('reply: stream_failed code=not_found');
        return (handled: false, answer: null, suggested: false);
      }
      _log('reply: stream_failed code=${_code(failure)}');
      feed?.dropPending(current: true);
      queue(replyFallbackText);
    } else if (last != null && last.replaced) {
      feed?.dropPending();
      if (last.text.trim().isEmpty) _log('reply: stream_failed code=empty_referral');
      queue(last.text.trim().isEmpty ? replyFallbackText : last.text);
    } else if (last != null && last.text.trim().isNotEmpty) {
      sentences.add(last.text);
      answer = sentences.join(' ');
      queue(last.text);
    } else if (spoke) {
      answer = sentences.join(' ');
    } else {
      _log('reply: stream_failed code=empty_reply');
      queue(replyFallbackText);
    }
    feed?.close();
    await playing;
    if (feed == null) _endTurn(id);
    return (handled: true, answer: answer, suggested: last?.councilSuggested ?? false);
  }

  Future<void> _speakTurn(int id, String text) {
    _speechTurn = id;
    return _playTurn(id, speech.speak(text));
  }

  Future<void> _playTurn(int id, Stream<PlaybackEvent> playback) async {
    await for (final e in playback) {
      if (_activeTurn != id) continue; // Cancelled; let the stream end.
      switch (e) {
        case PlaybackStarted(:final text):
          _echoing = true;
          try {
            dispatch(ReplyChunk(text));
          } finally {
            _echoing = false;
          }
        case PlaybackFailed(:final code):
          _log('reply: speech_failed code=$code');
        case PlaybackFinished() || PlaybackCancelled():
          break;
      }
    }
    if (_speechTurn == id) _speechTurn = null;
    _endTurn(id);
  }

  void _endTurn(int id) {
    if (_activeTurn != id) return;
    dispatch(const ReplyDone());
    _activeTurn = null;
  }

  /// Error code only: server codes pass when they look like codes.
  static String _code(Object e) {
    if (e is TimeoutException) return 'timeout';
    if (e is ServerException && RegExp(r'^[a-z_]{1,40}$').hasMatch(e.error)) return e.error;
    return 'reply_error';
  }

  Future<void> dispose() async {
    _pendingReply?.cancel();
    speech.cancel();
    modes.removeListener(_onMode);
    _listeners.clear();
    await _turns.close();
    await _listen.close();
  }
}
