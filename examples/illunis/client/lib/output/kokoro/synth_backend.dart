/// Seams for the Kokoro engine: [SynthBackend] turns one sentence into
/// samples, [PcmPlayer] plays them. Neither may log the sentence text.
library;

import 'dart:typed_data';

import 'kokoro_voices.dart';

abstract class SynthBackend {
  /// Output rate of the loaded model, in Hz.
  int get sampleRate;

  /// Synthesises one sentence to mono float samples in [-1, 1].
  Future<Float32List> synth(String sentence, KokoroVoice voice);

  Future<void> dispose();
}

/// Loads a backend for the model in [modelDir].
typedef SynthBackendLoader = Future<SynthBackend> Function(String modelDir, KokoroVoice voice);

/// Plays 16-bit mono PCM (AudioTrackPlayer in player.dart on Android).
abstract class PcmPlayer {
  /// Completes when the last sample is out, or at once after [stop].
  Future<void> play(Int16List pcm, int sampleRate);

  Future<void> stop();

  /// Stops and releases the native side. The player is unusable after.
  Future<void> dispose();
}

/// Float samples to 16-bit PCM, clamped.
Int16List toPcm16(Float32List samples) {
  final out = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    out[i] = (samples[i].clamp(-1.0, 1.0) * 32767).round();
  }
  return out;
}
