/// Whispered-input gate in front of the recogniser. A listening session's
/// PCM is buffered until an endpoint, then run through [prepareUtterance]
/// (hallucination guard, then one capped gain). A dropped utterance never
/// reaches the recogniser; the session ends with an empty final so the voice
/// state returns to idle. A kept one is handed to [recogniser] as one
/// normalised buffer. Logs carry codes and numbers only, never audio or text.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'input_ports.dart';
import 'mic_levels.dart';
import 'utterance_gain.dart';
import 'voice_gate.dart';

/// When a session's utterance ends. Defaults are first guesses, NOT measured;
/// check them with the Blade procedure in docs/RESEARCH.md (section 3).
class EndpointTuning {
  const EndpointTuning({
    this.trailingSilenceMs = 800,
    this.noSpeechMs = 6000,
    this.maxUtteranceMs = 15000,
    this.voiceAboveFloorDb = 8,
  });

  /// Silence after voice that ends the utterance.
  final int trailingSilenceMs;

  /// A chunk counts as voice when it is this many dB above the quietest chunk
  /// heard in the session. A fixed gate fails with a fan in the room: the fan
  /// alone kept the endpoint from ever closing (device test 2026-10-25).
  final double voiceAboveFloorDb;

  /// No voice at all for this long ends the session (then the guard drops it).
  final int noSpeechMs;

  /// Hard cap on one utterance.
  final int maxUtteranceMs;
}

class GatedSpeechToText implements SpeechToTextPort {
  GatedSpeechToText(
    this.recogniser, {
    this.tuning = const WhisperTuning(),
    this.endpoint = const EndpointTuning(),
    VoiceActivityDetector? vad,
    void Function(String line)? log,
  })  : vad = vad ?? EnergyVad(tuning),
        _log = log ?? debugPrint;

  final SpeechToTextPort recogniser;
  final WhisperTuning tuning;
  final EndpointTuning endpoint;
  final VoiceActivityDetector vad;
  final void Function(String line) _log;

  @override
  Stream<Utterance> transcribe(Stream<Uint8List> audio, {required int sampleRate}) {
    late final StreamController<Utterance> out;
    StreamSubscription<Uint8List>? audioSub;
    StreamSubscription<Utterance>? innerSub;
    final buffer = BytesBuilder(copy: true);
    var heardVoice = false;
    var totalMs = 0;
    var silenceMs = 0;
    var levelMs = 0;
    var floorDbfs = double.infinity;
    var ended = false;

    void finish(Utterance? last) {
      if (out.isClosed) return;
      if (last != null) out.add(last);
      if (!out.isClosed) unawaited(out.close());
    }

    void decode(Int16List samples) {
      final kept = prepareUtterance(samples, sampleRate,
          tuning: tuning,
          vad: vad,
          onDrop: (r) => _log('input: utterance_dropped reason=${r.name}'));
      if (kept == null) {
        finish(const Utterance('', isFinal: true)); // Back to idle.
        return;
      }
      _log('input: utterance_kept gain_db=${kept.gainDb.toStringAsFixed(1)}');
      var sawFinal = false;
      innerSub = recogniser
          .transcribe(Stream.value(pcm16ToBytes(kept.samples)), sampleRate: sampleRate)
          .listen((u) {
        sawFinal = sawFinal || u.isFinal;
        if (!out.isClosed) out.add(u);
      }, onError: (Object e) {
        if (!out.isClosed) out.addError(e);
      }, onDone: () => finish(sawFinal ? null : const Utterance('', isFinal: true)));
    }

    void onChunk(Uint8List chunk) {
      if (ended) return;
      buffer.add(chunk);
      final samples = pcm16FromBytes(chunk);
      final ms = durationMs(samples.length, sampleRate);
      totalMs += ms;
      levelMs += ms;
      final level = rmsDbfs(samples);
      final quiet = level < tuning.silenceFloorDbfs ? tuning.silenceFloorDbfs : level;
      if (quiet < floorDbfs) floorDbfs = quiet;
      if (kDebugMode && levelMs >= 2000) {
        levelMs = 0;
        _log('input: level rms_dbfs=${level.toStringAsFixed(1)} '
            'floor_dbfs=${floorDbfs.toStringAsFixed(1)} heard=$heardVoice total_ms=$totalMs');
      }
      if (level >= floorDbfs + endpoint.voiceAboveFloorDb) {
        heardVoice = true;
        silenceMs = 0;
      } else {
        silenceMs += ms;
      }
      final done = (heardVoice && silenceMs >= endpoint.trailingSilenceMs) ||
          (!heardVoice && totalMs >= endpoint.noSpeechMs) ||
          totalMs >= endpoint.maxUtteranceMs;
      if (!done) return;
      ended = true;
      unawaited(audioSub?.cancel());
      audioSub = null;
      decode(pcm16FromBytes(buffer.takeBytes()));
    }

    out = StreamController<Utterance>(
      sync: true,
      onListen: () => audioSub = audio.listen(onChunk),
      onCancel: () async {
        ended = true;
        await audioSub?.cancel();
        await innerSub?.cancel();
      },
    );
    return out.stream;
  }
}
