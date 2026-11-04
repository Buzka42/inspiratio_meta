/// Platform-channel side of the microphone: `illunis/mic` (methods) and
/// `illunis/mic/pcm` (PCM16 chunks), served by MicChannelHandler.kt and
/// MicCaptureService.kt. Not wired into main.dart yet (lib/app owns that).
/// Not run on a device.
library;

import 'package:flutter/services.dart';

import 'input_ports.dart';

const _methods = MethodChannel('illunis/mic');
const _pcm = EventChannel('illunis/mic/pcm');

class ChannelMicPermission implements MicPermissionPort {
  @override
  Future<MicPermission> request() async {
    try {
      final r = await _methods.invokeMethod<String>('requestPermission');
      return r == 'granted' ? MicPermission.granted : MicPermission.denied;
    } on MissingPluginException {
      return MicPermission.unavailable;
    } on PlatformException {
      return MicPermission.unavailable;
    }
  }
}

/// AudioRecord at 16 kHz mono PCM16, source VOICE_RECOGNITION (MIC as
/// fallback), AGC and NS off. Start only from a user interaction.
class ChannelAudioCapture implements AudioCapturePort {
  @override
  int get sampleRate => 16000;

  @override
  late final Stream<Uint8List> chunks =
      _pcm.receiveBroadcastStream().map((e) => e as Uint8List);

  @override
  Future<void> start() => _methods.invokeMethod<void>('startCapture');

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stopCapture');

  /// Source and effect state of the running capture, for the Blade log:
  /// {source, agcAvailable, agcEnabled, nsAvailable, nsEnabled}. Empty when
  /// not capturing.
  Future<Map<String, Object?>> captureInfo() async =>
      (await _methods.invokeMapMethod<String, Object?>('captureInfo')) ?? const {};
}
