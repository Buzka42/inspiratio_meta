/// TODO(native): STUBS. No speech engine package has been chosen (owner
/// decision; sherpa-onnx is the candidate for keyword spotting, faster-whisper
/// on the server for speech in), and no Kotlin side exists. These stubs keep
/// the app running without a device: the permission stub answers
/// [MicPermission.unavailable], so the pipeline stays off with the code
/// `mic_unavailable`. Nothing here records audio. Not verified on any device.
library;

import 'dart:typed_data';

import '../voice/voice_session.dart';
import '../voice/wake_keyword.dart';
import 'input_ports.dart';

/// TODO(native): request RECORD_AUDIO (Android runtime permission) and map
/// the result to [MicPermission]. Planned channel `illunis/mic`, method
/// `requestPermission`.
class StubMicPermission implements MicPermissionPort {
  @override
  Future<MicPermission> request() async => MicPermission.unavailable;
}

/// TODO(native): AudioRecord at 16 kHz mono PCM16 inside a microphone
/// foreground service; planned event channel `illunis/mic/pcm`. Android 14+
/// cannot start that service from an alarm with the screen off.
class StubAudioCapture implements AudioCapturePort {
  @override
  int get sampleRate => 16000;

  @override
  Stream<Uint8List> get chunks => const Stream.empty();

  @override
  Future<void> start() async =>
      throw UnsupportedError('audio capture not built (TODO native)');

  @override
  Future<void> stop() async {}
}

/// TODO(engine): keyword spotting with a keyword grammar for the user's own
/// word (sherpa-onnx KWS candidate; its model licences are unverified).
/// Measure false wakes before shipping.
class StubWakeWordPort implements WakeWordPort {
  @override
  Stream<WakeWordHeard> listen(Stream<Uint8List> audio, WakeKeyword keyword,
          {required int sampleRate}) =>
      const Stream.empty();
}

/// TODO(engine): stream audio to the speech-in engine (faster-whisper,
/// self-hosted, after the benchmark) and emit partial and final utterances.
/// Needs echo cancellation so Illunis's own voice is not taken as barge-in.
class StubSpeechToText implements SpeechToTextPort {
  @override
  Stream<Utterance> transcribe(Stream<Uint8List> audio, {required int sampleRate}) =>
      const Stream.empty();
}
