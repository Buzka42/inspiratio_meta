/// Test engine: records prepares and plays; playback is held until
/// [finishPlay] unless [autoFinish] is set. Synthetic text only.
library;

import 'dart:async';

import 'tts_engine.dart';

class FakeSpeech extends PreparedSpeech {
  const FakeSpeech(this.text);
  final String text;
}

class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({this.autoFinish = true, this.failOn});

  bool autoFinish;

  /// prepare() throws for this sentence.
  String? failOn;

  /// In order: `prepare:TEXT`, `play:TEXT`, `played:TEXT`, `stop`.
  final trace = <String>[];
  final played = <String>[];
  int stops = 0;
  Completer<void>? _playing;
  String? _current;

  bool get isPlaying => _playing != null;

  @override
  String get voiceId => 'fake';
  @override
  int get sampleRate => 24000;

  @override
  Future<PreparedSpeech> prepare(String sentence) async {
    trace.add('prepare:$sentence');
    if (sentence == failOn) throw StateError('synthetic');
    return FakeSpeech(sentence);
  }

  @override
  Future<void> play(PreparedSpeech speech) {
    final t = (speech as FakeSpeech).text;
    trace.add('play:$t');
    _current = t;
    final c = _playing = Completer<void>();
    if (autoFinish) scheduleMicrotask(finishPlay);
    return c.future;
  }

  /// Ends the current sentence normally.
  void finishPlay() {
    final c = _playing;
    if (c == null) return;
    _playing = null;
    played.add(_current!);
    trace.add('played:$_current');
    c.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    trace.add('stop');
    final c = _playing;
    _playing = null;
    c?.complete();
  }
}
