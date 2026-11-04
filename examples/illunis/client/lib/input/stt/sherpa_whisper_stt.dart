/// On-device speech-to-text behind [SpeechToTextPort]: sherpa-onnx Whisper
/// tiny.en (PLAN.md, decisions 2026-10-24). It sits behind
/// GatedSpeechToText, which hands it one normalised 16 kHz PCM16 buffer per
/// kept utterance; this adapter turns that into float samples, runs one
/// decode on the worker isolate ([IsolateWhisperRecogniser]) and emits one
/// final [Utterance]. A failed decode logs a code and that utterance goes to
/// [fallback] (the stub, which ends the session with no text).
///
/// Logs carry codes and numbers only, never the transcript or audio.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../input_ports.dart';
import 'whisper_model.dart';
import 'whisper_recogniser.dart';

class SherpaWhisperStt implements SpeechToTextPort {
  SherpaWhisperStt({
    required this.recogniser,
    required this.fallback,
    void Function(String line)? log,
  }) : _log = log ?? debugPrint;

  /// The adapter for the model in [modelDir]. Throws [WhisperFailure] with
  /// [sttModelMissing] (naming the missing file names) before any native code
  /// loads when a file is absent. [build] and [exists] are test seams.
  factory SherpaWhisperStt.fromDir(
    String modelDir, {
    required SpeechToTextPort fallback,
    WhisperRecogniser Function(WhisperModel model)? build,
    bool Function(String path)? exists,
    void Function(String line)? log,
  }) {
    final model = WhisperModel.inDir(modelDir);
    final missing = model.missing(exists);
    if (missing.isNotEmpty) {
      throw WhisperFailure(sttModelMissing,
          'not bundled, push to $whisperModelSubdir: ${missing.map(_base).join(', ')}');
    }
    final recogniser = (build ?? _defaultBuild)(model);
    return SherpaWhisperStt(recogniser: recogniser, fallback: fallback, log: log);
  }

  final WhisperRecogniser recogniser;
  final SpeechToTextPort fallback;
  final void Function(String line) _log;

  @override
  Stream<Utterance> transcribe(Stream<Uint8List> audio, {required int sampleRate}) async* {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in audio) {
      bytes.add(chunk);
    }
    final pcm = bytes.takeBytes();
    final samples = pcm16BytesToFloat32(pcm);
    if (samples.isEmpty) {
      yield const Utterance('', isFinal: true);
      return;
    }
    final String text;
    final clock = Stopwatch()..start();
    try {
      text = await recogniser.recognise(samples, sampleRate);
    } catch (e) {
      _log('input: stt_failed code=${e is WhisperFailure ? e.code : 'stt_error'}');
      yield* fallback.transcribe(Stream.value(pcm), sampleRate: sampleRate);
      return;
    }
    final audioMs = samples.length * 1000 ~/ sampleRate;
    _log('input: stt_done audio_ms=$audioMs proc_ms=${clock.elapsedMilliseconds} '
        'empty=${text.isEmpty}');
    // Device tuning only: off unless built with ILLUNIS_LOG_TRANSCRIPTS=true. Never in release builds.
    if (_logTranscripts && !kReleaseMode) _log('input: heard="$text"');
    yield Utterance(text, isFinal: true);
  }

  Future<void> dispose() => recogniser.dispose();
}

WhisperRecogniser _defaultBuild(WhisperModel model) =>
    IsolateWhisperRecogniser(model)..warmUp();

String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

/// 16-bit little-endian mono PCM to float samples in [-1, 1). An odd
/// trailing byte is dropped.
Float32List pcm16BytesToFloat32(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final out = Float32List(pcm.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// The recogniser for the app: [SherpaWhisperStt] when the model is in
/// [modelDir], else [fallback] with `input: stt_engine_off code=<code>`.
/// Same pattern as chooseWakeWordPort (voice/wake_wiring.dart). Never throws.
SpeechToTextPort chooseSpeechToText({
  required SpeechToTextPort fallback,
  required String modelDir,
  WhisperRecogniser Function(WhisperModel model)? build,
  bool Function(String path)? exists,
  void Function(String line)? log,
}) {
  final say = log ?? debugPrint;
  try {
    final stt = SherpaWhisperStt.fromDir(modelDir,
        fallback: fallback, build: build, exists: exists, log: say);
    say('input: stt_engine_on');
    return stt;
  } catch (e) {
    say('input: stt_engine_off code=${e is WhisperFailure ? e.code : sttLoadFailed}');
    return fallback;
  }
}

const _logTranscripts = bool.fromEnvironment('ILLUNIS_LOG_TRANSCRIPTS');
