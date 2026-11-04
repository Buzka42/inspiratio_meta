/// Spoken breathwork cues (build plan B1, B7 and E3, E4). The only voice
/// path while the app's voice switch (core/voice_flags.dart) is off: it
/// drives the Kokoro [TtsEngine] directly, not through the main
/// SpeechOutput. Speech out only; there is no voice input here.
///
/// Without the licence gate (ILLUNIS_KOKORO_GPL_CHECKED) or a ready Kokoro
/// engine, nothing is spoken and the view shows the cue text alone. Never
/// logs cue text.
library;

import 'dart:async';

import '../app/speech_wiring.dart';
import '../output/kokoro/kokoro_licence.dart';
import '../output/tts_engine.dart';
import 'technique.dart';

class BreathVoice {
  /// [engine] is the Kokoro engine. [allowed] defaults to the licence flag;
  /// pass false for screen-only.
  BreathVoice({TtsEngine? engine, bool allowed = kokoroGplCheckedFlag}) : _engine = allowed ? engine : null;

  /// From the app's speech wiring: speaks only when Kokoro is ready there
  /// and the licence gate is set.
  factory BreathVoice.fromWiring(SpeechWiring wiring, {bool releaseChecked = kokoroGplCheckedFlag}) =>
      BreathVoice(engine: wiring.engine, allowed: releaseChecked && wiring.kokoro);

  /// Screen only: cues are shown, never spoken.
  BreathVoice.silent() : _engine = null;

  final TtsEngine? _engine;
  Future<void>? _speaking;
  int _gen = 0;

  /// True when cues can be spoken.
  bool get canSpeak => _engine != null;

  /// Speaks [cue] when it is marked `speak` and speech is allowed. Returns
  /// true when it was sent to the engine. A failing engine is ignored: the
  /// cue text is on screen either way.
  bool speak(Cue cue) {
    final e = _engine;
    if (e == null || !cue.speak) return false;
    final prev = _speaking;
    final gen = _gen;
    _speaking = () async {
      try {
        await prev;
        if (gen != _gen) return;
        final s = await e.prepare(cue.text);
        if (gen != _gen) return;
        await e.play(s);
      } on Object {
        // On-screen text stays; no text in logs.
      }
    }();
    return true;
  }

  /// Stops any cue now (Pause or Stop).
  Future<void> stop() async {
    final e = _engine;
    _speaking = null;
    _gen++;
    if (e != null) {
      try {
        await e.stop();
      } on Object {
        // Nothing playing.
      }
    }
  }
}
