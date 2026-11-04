/// Microphone input ports. The speech engine is an open owner decision, so
/// everything here is an interface: fakes live in input_fakes.dart and the
/// native TODO stubs in input_stubs.dart.
library;

import 'dart:typed_data';

import '../voice/voice_session.dart';
import '../voice/wake_keyword.dart';

enum MicPermission { granted, denied, unavailable }

abstract class MicPermissionPort {
  /// Asks for RECORD_AUDIO (shows the system screen when needed).
  Future<MicPermission> request();
}

/// Raw microphone audio: 16-bit little-endian mono PCM.
abstract class AudioCapturePort {
  int get sampleRate;

  /// PCM chunks while capturing. Single subscription is enough; the pipeline
  /// fans it out to the wake word and speech engines.
  Stream<Uint8List> get chunks;

  Future<void> start();
  Future<void> stop();
}

abstract class WakeWordPort {
  /// Emits [WakeWordHeard] each time [keyword] is spotted in [audio].
  /// Cancelling the returned subscription stops spotting.
  Stream<WakeWordHeard> listen(
    Stream<Uint8List> audio,
    WakeKeyword keyword, {
    required int sampleRate,
  });
}

class Utterance {
  const Utterance(this.text, {this.isFinal = false});
  final String text;

  /// True when the engine has ended the utterance (endpoint reached).
  final bool isFinal;
}

abstract class SpeechToTextPort {
  /// Transcribes [audio] into partial and final utterances until the
  /// returned subscription is cancelled.
  Stream<Utterance> transcribe(Stream<Uint8List> audio, {required int sampleRate});
}
