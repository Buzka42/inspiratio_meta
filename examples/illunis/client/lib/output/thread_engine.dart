/// Text-only [TtsEngine] for the chat (voice off, core/voice_flags.dart).
/// [play] hands each sentence to [append] (the chat thread) and returns at
/// once, so [SpeechOutput] and everything built on it (replies, prompts,
/// asides, council answers) write into the thread instead of speaking.
/// No audio, no logs.
library;

import 'tts_engine.dart';

class _Sentence extends PreparedSpeech {
  const _Sentence(this.text);
  final String text;
}

class ThreadEngine implements TtsEngine {
  ThreadEngine(this.append);

  /// Receives each sentence in order (ChatThread.addAssistant in the app).
  final void Function(String sentence) append;

  @override
  String get voiceId => 'thread';
  @override
  int get sampleRate => 0;

  @override
  Future<PreparedSpeech> prepare(String sentence) async => _Sentence(sentence);

  @override
  Future<void> play(PreparedSpeech speech) async => append((speech as _Sentence).text);

  /// Nothing plays, so there is nothing to stop.
  @override
  Future<void> stop() async {}
}
