/// The swappable speech synthesis engine behind [SpeechOutput]. Kokoro is the
/// target (see kokoro_tts_stub.dart). Engines never log text.
library;

import '../app/tts_port.dart';

/// Audio ready to play, opaque to callers. Each engine subclasses it.
abstract class PreparedSpeech {
  const PreparedSpeech();
}

abstract class TtsEngine {
  /// Engine voice id, for example a Kokoro English voice.
  String get voiceId;

  /// Output sample rate in Hz.
  int get sampleRate;

  /// Synthesizes one sentence. May run while another sentence plays.
  Future<PreparedSpeech> prepare(String sentence);

  /// Plays [speech]; completes when playback ends or [stop] is called.
  Future<void> play(PreparedSpeech speech);

  /// Stops playback at once (barge-in).
  Future<void> stop();
}

class _TextSpeech extends PreparedSpeech {
  const _TextSpeech(this.text);
  final String text;
}

/// Adapter over the older [TtsPort] (for example [SilentTts]): "audio" is the
/// sentence text, and playing it calls [TtsPort.speak].
class TtsPortEngine implements TtsEngine {
  TtsPortEngine(this.port);
  final TtsPort port;

  @override
  String get voiceId => 'none';
  @override
  int get sampleRate => 0;

  @override
  Future<PreparedSpeech> prepare(String sentence) async => _TextSpeech(sentence);

  @override
  Future<void> play(PreparedSpeech speech) =>
      port.speak((speech as _TextSpeech).text);

  @override
  Future<void> stop() => port.stop();
}
