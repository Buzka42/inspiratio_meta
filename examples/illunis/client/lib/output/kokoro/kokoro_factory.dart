/// One place that builds speech out from Kokoro: [KokoroTtsEngine] on the
/// sherpa-onnx backend, playing through [AudioTrackPlayer]. The result plugs
/// into [SpeechOutput] as a [TtsEngine].
///
/// The licence gate runs first. Refused (the default), the build carries the
/// old silent stub and a fixed refusal code, and no native code is touched.
/// Never logs text.
library;

import '../kokoro_tts_stub.dart' as stub;
import '../tts_engine.dart';
import 'kokoro_engine.dart';
import 'kokoro_licence.dart';
import 'kokoro_voices.dart';
import 'player.dart';
import 'sherpa_backend.dart';
import 'synth_backend.dart';

/// Fixed refusal codes.
abstract final class KokoroRefusal {
  /// The espeak-ng release check is not confirmed (see kokoro_licence.dart).
  static const licence = 'kokoro_licence_refused';

  /// The voice is not an English Kokoro voice.
  static const voice = 'kokoro_bad_voice';
}

class KokoroBuild {
  const KokoroBuild._(this.engine, this.refusal, this._kokoro);

  /// The engine to hand to [SpeechOutput]: Kokoro when [ready], else the stub.
  final TtsEngine engine;

  /// A [KokoroRefusal] code, or null when Kokoro is ready.
  final String? refusal;

  final KokoroTtsEngine? _kokoro;

  bool get ready => refusal == null;

  /// Releases the player and the backend. Safe on a refused build.
  Future<void> dispose() async => _kokoro?.dispose();
}

/// Builds Kokoro speech out for the model in [modelDir].
///
/// [releaseChecked] defaults to the compile-time gate flag. [player] and
/// [loader] are seams for tests; by default they are [AudioTrackPlayer] and
/// the sherpa-onnx backend.
KokoroBuild buildKokoroSpeech(
  String modelDir, {
  String voice = defaultKokoroVoice,
  bool releaseChecked = kokoroGplCheckedFlag,
  PcmPlayer Function()? player,
  SynthBackendLoader? loader,
}) {
  try {
    checkKokoroLicence(releaseChecked: releaseChecked);
  } on KokoroLicenceRefused {
    return _refused(KokoroRefusal.licence);
  }
  final KokoroVoice v;
  try {
    v = kokoroVoice(voice);
  } on ArgumentError {
    return _refused(KokoroRefusal.voice);
  }
  final engine = KokoroTtsEngine(
    modelDir,
    voice: v.name,
    player: (player ?? AudioTrackPlayer.new)(),
    loader: loader ??
        (dir, voice) => SherpaKokoroBackend.load(dir, voice, releaseChecked: releaseChecked),
  );
  return KokoroBuild._(engine, null, engine);
}

KokoroBuild _refused(String code) => KokoroBuild._(const stub.KokoroTtsEngine(), code, null);
