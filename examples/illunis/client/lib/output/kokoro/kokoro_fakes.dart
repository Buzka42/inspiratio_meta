/// Test doubles for the Kokoro engine. Synthetic text only.
library;

import 'dart:async';
import 'dart:typed_data';

import 'kokoro_voices.dart';
import 'synth_backend.dart';

/// Returns one sample per character (value 0.5) and records each call.
class FakeSynthBackend implements SynthBackend {
  FakeSynthBackend({this.sampleRate = 24000});

  @override
  final int sampleRate;

  /// In order: `TEXT@VOICE`.
  final calls = <String>[];
  bool disposed = false;

  @override
  Future<Float32List> synth(String sentence, KokoroVoice voice) async {
    calls.add('$sentence@${voice.name}');
    return Float32List(sentence.length)..fillRange(0, sentence.length, 0.5);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// Holds each play until [finish] unless [autoFinish]; records sample counts.
class FakePcmPlayer implements PcmPlayer {
  FakePcmPlayer({this.autoFinish = true});

  bool autoFinish;
  final played = <int>[];
  int stops = 0;
  bool disposed = false;
  Completer<void>? _playing;

  bool get isPlaying => _playing != null;

  @override
  Future<void> play(Int16List pcm, int sampleRate) {
    played.add(pcm.length);
    final c = _playing = Completer<void>();
    if (autoFinish) scheduleMicrotask(finish);
    return c.future;
  }

  void finish() {
    final c = _playing;
    _playing = null;
    c?.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }

  @override
  Future<void> dispose() async {
    finish();
    disposed = true;
  }
}
