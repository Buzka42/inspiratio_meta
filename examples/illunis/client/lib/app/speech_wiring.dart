/// Chooses the speech engine at start-up: Kokoro when the build is ready and
/// the model files are on the device, else the silent captions-only path.
/// Logs a fixed code only, never text or paths.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../output/kokoro/kokoro_factory.dart';
import '../output/tts_engine.dart';

/// The Kokoro model directory, relative to the app support directory
/// (Android: /data/user/0/com.illunis.illunis_client/files).
///
/// The model archive is NOT bundled in the APK (size, and the espeak-ng
/// licence check in kokoro_licence.dart). For testing it is pushed to the
/// device with tool/push_kokoro_model.sh (adb push + run-as).
const kokoroModelSubdir = 'models/kokoro-multi-lang-v1_0';

/// Files the sherpa-onnx backend reads for an American voice (af_heart).
const kokoroModelFiles = ['model.onnx', 'voices.bin', 'tokens.txt', 'lexicon-us-en.txt'];

/// Default voice (PLAN.md).
const kokoroAppVoice = 'af_heart';

/// Refusal code when the build is ready but the model is not on the device.
/// Checked before the backend loads, so native code never sees a missing file.
const kokoroModelMissing = 'kokoro_model_missing';

/// The model directory under [baseDir] (the app support directory).
String kokoroModelDir(String baseDir) {
  final base = baseDir.endsWith('/') ? baseDir.substring(0, baseDir.length - 1) : baseDir;
  return '$base/$kokoroModelSubdir';
}

/// Kokoro's engine when [build] is ready, else [fallback].
TtsEngine chooseSpeechEngine(KokoroBuild build, TtsEngine fallback) =>
    build.ready ? build.engine : fallback;

class SpeechWiring {
  const SpeechWiring(this.engine, this.refusal, this._build);

  /// The engine to hand to SpeechOutput.
  final TtsEngine engine;

  /// A refusal code, or null when Kokoro speaks.
  final String? refusal;

  final KokoroBuild _build;

  bool get kokoro => refusal == null;

  /// Releases the Kokoro player and backend. Safe on the fallback.
  Future<void> dispose() => _build.dispose();
}

/// Builds speech for the app support directory [baseDir]. [build] and
/// [exists] are seams for tests.
Future<SpeechWiring> wireSpeech(
  String baseDir, {
  required TtsEngine fallback,
  KokoroBuild Function(String modelDir)? build,
  bool Function(String path)? exists,
  void Function(String line)? log,
}) async {
  final say = log ?? debugPrint;
  final dir = kokoroModelDir(baseDir);
  final b = (build ?? (d) => buildKokoroSpeech(d, voice: kokoroAppVoice))(dir);
  if (!b.ready) {
    say('speech: kokoro_off code=${b.refusal}');
    return SpeechWiring(fallback, b.refusal, b);
  }
  final has = exists ?? (p) => File(p).existsSync();
  if (!kokoroModelFiles.every((f) => has('$dir/$f'))) {
    await b.dispose();
    say('speech: kokoro_off code=$kokoroModelMissing');
    return SpeechWiring(fallback, kokoroModelMissing, b);
  }
  return SpeechWiring(chooseSpeechEngine(b, fallback), null, b);
}
