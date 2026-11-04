/// TODO(owner): Kokoro speech out. NOT IMPLEMENTED; nothing here produces
/// audio. The engine and model are an owner decision (candidate: sherpa-onnx
/// running Kokoro on device, or a self-hosted Kokoro server). A real
/// implementation must:
///  - load the chosen Kokoro model and English voice ([voiceId]);
///  - return 16-bit mono PCM at [sampleRate] from [prepare];
///  - play through a native audio channel and complete [play] when the last
///    sample is out, or at once after [stop];
///  - never log the sentence text.
library;

import 'tts_engine.dart';

/// PCM produced by a real Kokoro engine (expected shape).
class KokoroAudio extends PreparedSpeech {
  const KokoroAudio(this.pcm16, this.sampleRate);
  final List<int> pcm16;
  final int sampleRate;
}

class KokoroTtsEngine implements TtsEngine {
  /// Kokoro's published output rate is 24 kHz; confirm against the model used.
  const KokoroTtsEngine({this.voiceId = 'af_heart', this.sampleRate = 24000});

  @override
  final String voiceId;
  @override
  final int sampleRate;

  @override
  Future<PreparedSpeech> prepare(String sentence) =>
      Future.error(UnsupportedError('kokoro_not_wired'));

  @override
  Future<void> play(PreparedSpeech speech) =>
      Future.error(UnsupportedError('kokoro_not_wired'));

  @override
  Future<void> stop() async {}
}
