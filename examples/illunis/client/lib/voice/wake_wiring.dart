/// Chooses the wake port at each listen: the sherpa-onnx
/// engine for the stored 2 to 4 word phrase when its model is on the device,
/// else the old single-word port. Built on [selectWakeWordPort]. Logs codes
/// only, never the phrase or a path.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../input/input_ports.dart';
import '../input/wake/sherpa_wake_engine.dart';
import '../input/wake/wake_phrase.dart';
import '../input/wake_engine_adapter.dart';
import 'voice_session.dart';
import 'wake_keyword.dart';

/// The KWS model directory, relative to the app support directory (Android:
/// /data/user/0/com.illunis.illunis_client/files), same pattern as the
/// Kokoro model (app/speech_wiring.dart). NOT bundled in the APK: the owner
/// pushes it to the device (file list in sherpa_wake_engine.dart).
const kwsModelSubdir = 'models/kws/$kwsModelName';

/// Code logged when a phrase is set but the model files are not on the device.
const wakeModelMissing = 'wake_model_missing';

String kwsModelDir(String baseDir) {
  final base = baseDir.endsWith('/') ? baseDir.substring(0, baseDir.length - 1) : baseDir;
  return '$base/$kwsModelSubdir';
}

/// [legacy] unless [enginePhrase] is valid and every model file in
/// [modelDir] exists; then [buildEngine]'s port. [exists] is a test seam.
WakeWordPort chooseWakeWordPort({
  required WakeWordPort legacy,
  required String? enginePhrase,
  required String modelDir,
  required WakeWordPort Function(WakePhrase phrase, SherpaKwsModel model) buildEngine,
  bool Function(String path)? exists,
  void Function(String line)? log,
}) =>
    selectWakeWordPort(
      legacy: legacy,
      enginePhrase: enginePhrase,
      buildEngine: (phrase) {
        final model = SherpaKwsModel.inDir(modelDir);
        final has = exists ?? (p) => File(p).existsSync();
        if (!model.files.every(has)) {
          (log ?? debugPrint)('input: wake_engine_off code=$wakeModelMissing');
          return legacy;
        }
        return buildEngine(phrase, model);
      },
    );

/// The app's engine port: a [WakeEngineAdapter] over [SherpaWakeEngine],
/// fed the pipeline audio through a relay, falling back to [fallback] when
/// the engine cannot start.
WakeWordPort sherpaWakePort(WakePhrase phrase, SherpaKwsModel model, WakeWordPort fallback) {
  final relay = WakeAudioRelay();
  return WakeEngineAdapter(
    engine: SherpaWakeEngine(model: model, openAudio: relay.open),
    phrase: phrase,
    fallback: fallback,
    audioRelay: relay,
  );
}

/// Picks the port again on every [listen], so a phrase saved during setup
/// takes effect when the pipeline restarts spotting (refreshKeyword). The
/// chosen port is kept while the phrase is unchanged, so its debounce state
/// survives restarts.
class PhraseSwitchingWakePort implements WakeWordPort {
  PhraseSwitchingWakePort({required this.phrase, required this.choose});

  /// The stored phrase text, or null when none is set.
  final String? Function() phrase;
  final WakeWordPort Function(String? phrase) choose;

  String? _for;
  WakeWordPort? _port;

  /// The port used by the last [listen] (null before the first).
  WakeWordPort? get current => _port;

  @override
  Stream<WakeWordHeard> listen(Stream<Uint8List> audio, WakeKeyword keyword,
      {required int sampleRate}) {
    final p = phrase();
    if (_port == null || p != _for) {
      _port = choose(p);
      _for = p;
    }
    return _port!.listen(audio, keyword, sampleRate: sampleRate);
  }
}
