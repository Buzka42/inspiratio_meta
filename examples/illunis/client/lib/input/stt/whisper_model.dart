/// sherpa-onnx Whisper tiny.en model layout (PLAN.md, decisions 2026-10-24).
///
/// MODEL FILES ARE NOT BUNDLED. The owner pushes them; nothing here fetches
/// anything. File names follow the k2-fsa release sherpa-onnx-whisper-tiny.en
/// as benchmarked in eval/stt (results.txt: int8 and fp32 give the same
/// transcripts, int8 is the smaller pair, so the app uses int8):
///
///   {app support dir}/models/stt/sherpa-onnx-whisper-tiny.en/
///     tiny.en-encoder.int8.onnx
///     tiny.en-decoder.int8.onnx
///     tiny.en-tokens.txt
library;

import 'dart:io';

const whisperModelName = 'sherpa-onnx-whisper-tiny.en';

/// Relative to the app support directory (Android:
/// /data/user/0/com.illunis.illunis_client/files), like the KWS model.
const whisperModelSubdir = 'models/stt/$whisperModelName';

String whisperModelDir(String baseDir) {
  final base = baseDir.endsWith('/') ? baseDir.substring(0, baseDir.length - 1) : baseDir;
  return '$base/$whisperModelSubdir';
}

class WhisperModel {
  const WhisperModel({required this.encoder, required this.decoder, required this.tokens});

  /// Default int8 file names inside [dir] (see the library comment).
  factory WhisperModel.inDir(String dir) => WhisperModel(
        encoder: '$dir/tiny.en-encoder.int8.onnx',
        decoder: '$dir/tiny.en-decoder.int8.onnx',
        tokens: '$dir/tiny.en-tokens.txt',
      );

  final String encoder;
  final String decoder;
  final String tokens;

  List<String> get files => [encoder, decoder, tokens];

  /// Files that are not present. [exists] is a test seam.
  List<String> missing([bool Function(String path)? exists]) {
    final has = exists ?? (p) => File(p).existsSync();
    return files.where((f) => !has(f)).toList();
  }
}
