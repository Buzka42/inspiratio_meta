/// Real microphone for the input pipeline: RECORD_AUDIO is asked once
/// through `illunis/mic` (ChannelMicPermission) and, when granted, the
/// pipeline gets the live capture on `illunis/mic/pcm` behind
/// [SafeAudioCapture]. Any other answer keeps the TODO stubs, so the app runs
/// as before. Logs carry codes only, never audio, messages or text.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'input_ports.dart';
import 'input_stubs.dart';

/// Logged when the microphone cannot start or its stream fails.
const micUnavailable = 'mic_unavailable';

/// Thrown by [SafeAudioCapture.start] in place of the native error, so no
/// platform message reaches a log.
class MicUnavailable implements Exception {
  const MicUnavailable();

  @override
  String toString() => 'MicUnavailable';
}

/// A permission answer already obtained, so the pipeline does not ask again.
class FixedMicPermission implements MicPermissionPort {
  const FixedMicPermission(this.answer);
  final MicPermission answer;

  @override
  Future<MicPermission> request() async => answer;
}

class MicPorts {
  const MicPorts(this.permission, this.capture, {required this.live});
  final MicPermissionPort permission;
  final AudioCapturePort capture;

  /// True when [capture] is the real microphone.
  final bool live;
}

/// Asks [permission] once. Granted: the port built by [live]. Denied or
/// unavailable (no channel, an error): the stubs, with
/// `input: mic_fallback code=mic_denied|mic_unavailable`. Never throws.
Future<MicPorts> resolveMicPorts({
  required MicPermissionPort permission,
  required AudioCapturePort Function() live,
  void Function(String line)? log,
}) async {
  MicPermission p;
  try {
    p = await permission.request();
  } catch (_) {
    p = MicPermission.unavailable;
  }
  if (p == MicPermission.granted) {
    return MicPorts(const FixedMicPermission(MicPermission.granted), live(), live: true);
  }
  final code = p == MicPermission.denied ? 'mic_denied' : micUnavailable;
  (log ?? debugPrint)('input: mic_fallback code=$code');
  return MicPorts(StubMicPermission(), StubAudioCapture(), live: false);
}

/// Wraps the channel capture: chunks pass through unchanged and in order; a
/// stream error (the service could not open AudioRecord) is logged as
/// [micUnavailable] and swallowed; a failed start is logged the same way and
/// rethrown as [MicUnavailable]. One retry when the activity was not yet in
/// the foreground (`not_foreground`, startup race).
class SafeAudioCapture implements AudioCapturePort {
  SafeAudioCapture(
    this.inner, {
    void Function(String line)? log,
    this.retryDelay = const Duration(milliseconds: 500),
  }) : _log = log ?? debugPrint;

  final AudioCapturePort inner;
  final Duration retryDelay;
  final void Function(String line) _log;

  @override
  int get sampleRate => inner.sampleRate;

  @override
  late final Stream<Uint8List> chunks = inner.chunks.transform(
    StreamTransformer.fromHandlers(handleError: (_, _, _) => _log('input: $micUnavailable')),
  );

  @override
  Future<void> start() async {
    try {
      try {
        await inner.start();
      } on PlatformException catch (e) {
        if (e.code != 'not_foreground') rethrow;
        await Future<void>.delayed(retryDelay);
        await inner.start();
      }
    } catch (_) {
      _log('input: $micUnavailable');
      throw const MicUnavailable();
    }
  }

  @override
  Future<void> stop() => inner.stop();
}
