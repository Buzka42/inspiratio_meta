/// Chunked speech out. [SpeechOutput.speak] splits the text into sentences,
/// prepares the next sentence while the current one plays, and reports
/// playback as a stream of [PlaybackEvent]s. One voice at a time: a new
/// speak() cancels the previous one. [SpeechOutput.feed] queues text that
/// arrives over time (a streamed reply). Logs carry codes only, never text.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'sentence_splitter.dart';
import 'tts_engine.dart';

sealed class PlaybackEvent {
  const PlaybackEvent();
}

/// Sentence [index] (0-based) began playing.
class PlaybackStarted extends PlaybackEvent {
  const PlaybackStarted(this.index, this.text);
  final int index;
  final String text;
}

/// Every sentence played. Last event of the stream.
class PlaybackFinished extends PlaybackEvent {
  const PlaybackFinished();
}

/// [SpeechOutput.cancel] stopped playback. Last event of the stream.
class PlaybackCancelled extends PlaybackEvent {
  const PlaybackCancelled();
}

/// The engine failed ([code]: synth_failed or play_failed). Last event.
class PlaybackFailed extends PlaybackEvent {
  const PlaybackFailed(this.code);
  final String code;
}

typedef SpeechLog = void Function(String message);

class SpeechOutput {
  SpeechOutput(this.engine, {SpeechLog? log}) : _log = log ?? debugPrint;

  final TtsEngine engine;
  final SpeechLog _log;
  _Session? _current;

  bool get isSpeaking => _current != null;

  Stream<PlaybackEvent> speak(String text) {
    final f = feed()
      ..add(text)
      ..close();
    return f.events;
  }

  /// Opens a queue for text that arrives over time (a streamed reply).
  /// Cancels any current speech, like [speak]. Each [SpeechFeed.add] is split
  /// into sentences and played in order, one at a time; the next sentence is
  /// prepared while the current one plays. [cancel] ends the feed at once.
  SpeechFeed feed() {
    cancel();
    final s = _current = _Session(StreamController<PlaybackEvent>());
    unawaited(_run(s));
    return SpeechFeed._(this, s);
  }

  /// Stops playback and ends the current stream with [PlaybackCancelled].
  /// No-op when nothing is speaking.
  void cancel() {
    final s = _current;
    if (s == null) return;
    _current = null;
    s.end(const PlaybackCancelled());
    _stopEngine();
  }

  Future<void> _run(_Session s) async {
    var index = 0;
    while (!s.done) {
      _prefetch(s);
      final next = s.prepared;
      s.prepared = null;
      if (next == null) {
        if (s.closed) break;
        await s.waitForText();
        continue;
      }
      final epoch = s.epoch;
      final audio = await next.audio;
      if (s.done) return;
      if (epoch != s.epoch) continue; // Dropped before it started.
      if (audio == null) return _fail(s, 'synth_failed');
      // Prepare the next sentence while this one plays.
      _prefetch(s);
      s.out.add(PlaybackStarted(index++, next.text));
      try {
        await engine.play(audio);
      } catch (_) {
        if (!s.done) _fail(s, 'play_failed');
        return;
      }
    }
    if (s.done) return;
    if (identical(_current, s)) _current = null;
    s.end(const PlaybackFinished());
  }

  /// Starts preparing the first queued sentence when none is being prepared.
  void _prefetch(_Session s) {
    if (s.done || s.prepared != null || s.pending.isEmpty) return;
    final text = s.pending.removeFirst();
    s.prepared = (text: text, audio: _prepare(text));
  }

  void _stopEngine() {
    unawaited(engine.stop().catchError((Object e) {
      _log('speech: stop_failed error=${e.runtimeType}');
    }));
  }

  /// Never throws: a failed prepare yields null.
  Future<PreparedSpeech?> _prepare(String sentence) =>
      engine.prepare(sentence).then<PreparedSpeech?>((a) => a, onError: (Object _) => null);

  void _fail(_Session s, String code) {
    if (identical(_current, s)) _current = null;
    _log('speech: $code');
    s.end(PlaybackFailed(code));
  }
}

/// Text queued into one [SpeechOutput] session. Calls after the session ended
/// (finished, failed or cancelled) do nothing.
class SpeechFeed {
  SpeechFeed._(this._owner, this._s);
  final SpeechOutput _owner;
  final _Session _s;

  /// Playback of this feed; ends with Finished, Cancelled or Failed.
  Stream<PlaybackEvent> get events => _s.out.stream;

  /// Queues [text] after everything already queued.
  void add(String text) {
    if (_s.done || _s.closed) return;
    _s.pending.addAll(splitSentences(text));
    _owner._prefetch(_s);
    _s.wake();
  }

  /// No more text: the stream finishes once the queue has played.
  void close() {
    if (_s.done) return;
    _s.closed = true;
    _s.wake();
  }

  /// Drops every sentence that has not started playing. With [current],
  /// also stops the sentence now playing; later [add]s still play.
  void dropPending({bool current = false}) {
    if (_s.done) return;
    _s.pending.clear();
    _s.prepared = null;
    _s.epoch++;
    if (current) _owner._stopEngine();
  }
}

class _Session {
  _Session(this.out);
  final StreamController<PlaybackEvent> out;
  final pending = Queue<String>();
  ({String text, Future<PreparedSpeech?> audio})? prepared;
  bool done = false;
  bool closed = false;

  /// Bumped by [SpeechFeed.dropPending]; a sentence prepared under an older
  /// epoch is skipped.
  int epoch = 0;
  Completer<void>? _waiting;

  Future<void> waitForText() => (_waiting ??= Completer<void>()).future;

  void wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void end(PlaybackEvent last) {
    if (done) return;
    done = true;
    wake();
    out.add(last);
    unawaited(out.close());
  }
}
