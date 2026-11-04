/// Release gate for the real Kokoro backend.
///
/// Why: every sherpa-onnx Kokoro model archive ships an `espeak-ng-data/`
/// folder, and espeak-ng is GPLv3 with no exception clause. Shipping it (or a
/// native library that links espeak-ng) in the APK brings GPLv3 duties:
/// licence text and a source offer. sherpa-onnx 2.0.0 says it removed
/// espeak-ng and piper-phonemize (changelog #4055) and reads a lexicon file
/// instead. That reduces the risk, but nobody has checked the release APK yet.
/// Until the owner checks the APK's native libs and the model files it
/// carries, the real backend refuses to start unless the release flag is set.
///
/// Set the flag with `--dart-define=ILLUNIS_KOKORO_GPL_CHECKED=true` only after
/// that check. It defaults to false, so the gate refuses by default.
library;

/// The GPLv3 component that triggers the gate.
const kokoroGplComponent = 'espeak-ng-data (GPLv3)';

/// Folder name of the GPL data inside a Kokoro archive. Do not bundle it.
const kokoroGplDataDir = 'espeak-ng-data';

/// Compile-time release flag. Default false: refuse.
const kokoroGplCheckedFlag = bool.fromEnvironment('ILLUNIS_KOKORO_GPL_CHECKED');

class KokoroLicenceRefused implements Exception {
  const KokoroLicenceRefused();
  @override
  String toString() =>
      'KokoroLicenceRefused: $kokoroGplComponent release check not confirmed';
}

/// Throws [KokoroLicenceRefused] unless [releaseChecked] is true.
void checkKokoroLicence({bool releaseChecked = kokoroGplCheckedFlag}) {
  if (!releaseChecked) throw const KokoroLicenceRefused();
}
