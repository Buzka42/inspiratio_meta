import '../output/speech_output.dart';

/// Speech out for prompts (setup, check-ins, digest prompts, asides).
/// [SpeechOutputTts] plays them through the same [SpeechOutput] as replies,
/// so Kokoro speaks them and barge-in cancels them.
abstract class TtsPort {
  Future<void> speak(String text);

  /// Stops playback at once (barge-in).
  Future<void> stop();
}

/// No audio. Records what would have been spoken, for tests and the
/// placeholder build.
class SilentTts implements TtsPort {
  final spoken = <String>[];
  int stops = 0;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;
}

/// Prompts through the app's [SpeechOutput] (Kokoro when wired, the silent
/// engine otherwise). [speak] completes when playback ends, fails or is
/// cancelled; playback errors are logged by [SpeechOutput] and never thrown.
class SpeechOutputTts implements TtsPort {
  SpeechOutputTts(this.speech);

  final SpeechOutput speech;

  @override
  Future<void> speak(String text) async {
    try {
      await speech.speak(text).drain<void>();
    } catch (_) {
      // Logged as a fixed code by SpeechOutput; a prompt never breaks the flow.
    }
  }

  @override
  Future<void> stop() async => speech.cancel();
}
