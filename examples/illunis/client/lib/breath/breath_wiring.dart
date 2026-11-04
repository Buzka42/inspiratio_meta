/// What the breath view needs: the library (loaded once, its names
/// registered for typed requests such as "do box breathing"), the store for
/// the onboarding answers, and the cue voice.
library;

import '../app/persistence.dart';
import '../app/view_requests.dart';
import 'breath_library.dart';
import 'breath_onboarding.dart';
import 'breath_voice.dart';

class BreathDeps {
  /// [library] defaults to the bundled assets; [store] to the device store
  /// (opened on first use); [voice] to screen only. Main can pass
  /// `BreathVoice.fromWiring(speechWiring)` to speak cues with Kokoro.
  BreathDeps({Future<BreathLibrary>? library, this.store, BreathVoice? voice})
      : library = (library ?? BreathLibrary.loadBundled()).then((l) {
          registerBreathNames(l.names);
          return l;
        }),
        voice = voice ?? BreathVoice.silent() {
    // A failed load is shown by the view; it must not surface as an
    // unhandled error before the view asks.
    this.library.ignore();
  }

  final Future<BreathLibrary> library;
  final BreathVoice voice;
  /// The device store when null.
  final StateStore? store;

  late final BreathProfileStore profiles = BreathProfileStore(store ?? persistentStore());
}
