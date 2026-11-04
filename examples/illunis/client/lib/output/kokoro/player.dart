/// [PcmPlayer] on the native AudioTrack channel (AudioPlayerChannel.kt).
/// Sends only samples and a rate, never text. Not verified on a device.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'synth_backend.dart';

/// Channel name and methods, mirrored in AudioPlayerChannel.kt.
abstract final class AudioPlayerChannel {
  static const name = 'illunis/audio_player';

  /// `{sampleRate: int}`; (re)creates the track when the rate changes.
  static const init = 'init';

  /// Little-endian Int16 mono PCM as bytes. Returns 'played' once the last
  /// sample is out, or 'stopped' after [stop].
  static const write = 'write';

  /// Pauses, flushes and releases the track at once.
  static const stop = 'stop';

  /// Releases everything; [init] may be sent again later.
  static const dispose = 'dispose';
}

/// The native player is not there (host tests, desktop, other platforms).
class AudioPlayerUnavailable implements Exception {
  const AudioPlayerUnavailable();

  @override
  String toString() => 'AudioPlayerUnavailable: no native audio player on this platform';
}

/// The native player answered with an error code.
class AudioPlayerFailed implements Exception {
  const AudioPlayerFailed(this.code);

  final String code;

  @override
  String toString() => 'AudioPlayerFailed: $code';
}

class AudioTrackPlayer implements PcmPlayer {
  AudioTrackPlayer({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel(AudioPlayerChannel.name);

  final MethodChannel _ch;
  int? _rate;
  Completer<void>? _playing;
  bool _disposed = false;

  /// Completes when the last sample is out, or at once after [stop].
  /// Throws [AudioPlayerUnavailable] without the native side.
  @override
  Future<void> play(Int16List pcm, int sampleRate) async {
    if (_disposed) throw StateError('audio_player_disposed');
    if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
    final done = _playing = Completer<void>();
    try {
      if (_rate != sampleRate) {
        await _call(AudioPlayerChannel.init, {'sampleRate': sampleRate});
        _rate = sampleRate;
      }
      if (done.isCompleted) return; // stopped while initialising
      final bytes = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
      unawaited(_call(AudioPlayerChannel.write, bytes).then(
        (_) => _finish(done),
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
      ));
    } catch (e) {
      if (identical(_playing, done)) _playing = null;
      rethrow;
    }
    return done.future;
  }

  void _finish(Completer<void> c) {
    if (identical(_playing, c)) _playing = null;
    if (!c.isCompleted) c.complete();
  }

  /// Ends playback now. A no-op without the native side (nothing can play).
  @override
  Future<void> stop() async {
    final c = _playing;
    if (c != null) _finish(c);
    await _quiet(AudioPlayerChannel.stop);
  }

  /// Stops and releases the native track. The player is unusable after.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    _rate = null;
    await _quiet(AudioPlayerChannel.dispose);
  }

  Future<Object?> _call(String method, [Object? args]) async {
    try {
      return await _ch.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw const AudioPlayerUnavailable();
    } on PlatformException catch (e) {
      throw AudioPlayerFailed(e.code);
    }
  }

  Future<void> _quiet(String method) async {
    try {
      await _call(method);
    } on AudioPlayerUnavailable {
      // Host or another platform: nothing to stop.
    }
  }
}
