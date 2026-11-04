/// Whispered-input gate: voice activity, the hallucination guard and the
/// Blade level report. Pure functions over 16-bit mono PCM.
///
/// Every threshold lives in [WhisperTuning]; no number below is hard-coded
/// in the logic. The defaults are first guesses, NOT measured values.
library;

import 'dart:typed_data';

import 'mic_levels.dart';

/// Tuning for quiet speech. Defaults are placeholders until the fixed-phrase
/// procedure in docs/RESEARCH.md (section 3) is run on the Blade.
class WhisperTuning {
  const WhisperTuning({
    this.gateDbfs = kVoiceGateDbfs,
    this.frameMs = 30,
    this.minUtteranceMs = 400,
    this.minVoicedMs = 200,
    this.silenceFloorDbfs = -60,
    this.targetRmsDbfs = -20,
    this.peakCeilingDbfs = -1,
    this.maxGainDb = 30,
  });

  /// Frame RMS (dBFS) at or above which a frame counts as voice.
  final double gateDbfs;

  /// Energy-gate frame length.
  final int frameMs;

  /// Shorter utterances never reach the recogniser (Whisper hallucinates on
  /// short non-speech clips).
  final int minUtteranceMs;

  /// Fewer voiced milliseconds than this: dropped as noise.
  final int minVoicedMs;

  /// Utterance RMS below this is treated as silence: never amplified and
  /// dropped by the guard.
  final double silenceFloorDbfs;

  /// Normalisation aims the utterance RMS here.
  final double targetRmsDbfs;

  /// Normalised peak always stays below this.
  final double peakCeilingDbfs;

  /// Upper bound on the normalisation gain.
  final double maxGainDb;
}

/// MEASURE ON THE BLADE: energy-gate threshold in dBFS of frame RMS.
///
/// -55 dBFS is a guess placed between a quiet room (often -65 to -55) and a
/// whisper at about 30 cm (roughly -50 to -40) on a phone mic with AGC off.
/// Neither number has been measured on the Blade. Run the fixed phrase,
/// spoken and whispered, plus an ambient take, through [levelReport], then
/// set this between the ambient RMS and the whispered voiced-frame RMS.
const double kVoiceGateDbfs = -55;

/// Seam for the voice-activity detector. [EnergyVad] is the current one;
/// Silero VAD through sherpa-onnx (already a dependency, 16 kHz only) is the
/// planned replacement and must implement this same interface.
abstract interface class VoiceActivityDetector {
  /// One flag per [frameSamples]-long frame (a short tail counts as a frame).
  List<bool> voicedFrames(Int16List samples, int sampleRate);

  /// Samples per frame at [sampleRate].
  int frameSamples(int sampleRate);
}

/// Frame-RMS energy gate. Cannot tell a whisper from a fan of the same
/// level; that is why Silero is planned.
class EnergyVad implements VoiceActivityDetector {
  const EnergyVad([this.tuning = const WhisperTuning()]);
  final WhisperTuning tuning;

  @override
  int frameSamples(int sampleRate) =>
      ((sampleRate * tuning.frameMs) ~/ 1000).clamp(1, 1 << 20);

  @override
  List<bool> voicedFrames(Int16List samples, int sampleRate) {
    final f = frameSamples(sampleRate);
    final gate = dbfsToAmp(tuning.gateDbfs);
    return [
      for (var i = 0; i < samples.length; i += f)
        rmsAmp(samples, i, (i + f).clamp(0, samples.length)) >= gate,
    ];
  }
}

/// Milliseconds of voiced audio according to [vad].
int voicedMs(Int16List samples, int sampleRate, VoiceActivityDetector vad) {
  final f = vad.frameSamples(sampleRate);
  final flags = vad.voicedFrames(samples, sampleRate);
  var n = 0;
  for (var k = 0; k < flags.length; k++) {
    if (!flags[k]) continue;
    final start = k * f;
    n += ((start + f).clamp(0, samples.length) - start);
  }
  return durationMs(n, sampleRate);
}

/// Why an utterance was kept from the recogniser.
enum GuardDrop { tooShort, belowFloor, noVoice }

/// Hallucination guard: null means pass; otherwise the reason to drop.
/// Runs before normalisation so silence is never amplified into "speech".
GuardDrop? guardUtterance(
  Int16List samples,
  int sampleRate, {
  WhisperTuning tuning = const WhisperTuning(),
  VoiceActivityDetector? vad,
}) {
  if (durationMs(samples.length, sampleRate) < tuning.minUtteranceMs) {
    return GuardDrop.tooShort;
  }
  if (rmsDbfs(samples) < tuning.silenceFloorDbfs) return GuardDrop.belowFloor;
  final v = vad ?? EnergyVad(tuning);
  if (voicedMs(samples, sampleRate, v) < tuning.minVoicedMs) return GuardDrop.noVoice;
  return null;
}

/// Level report for the Blade rig: same phrase, same distance, compare lines.
LevelReport levelReport(
  Int16List samples,
  int sampleRate, {
  String label = 'take',
  WhisperTuning tuning = const WhisperTuning(),
  VoiceActivityDetector? vad,
}) =>
    LevelReport(
      label: label,
      durationMs: durationMs(samples.length, sampleRate),
      rmsDbfs: rmsDbfs(samples),
      peakDbfs: peakDbfs(samples),
      voicedMs: voicedMs(samples, sampleRate, vad ?? EnergyVad(tuning)),
      gateDbfs: tuning.gateDbfs,
    );

/// Writes [report] as one tab-separated line to [out] (a File's IOSink,
/// stdout or a StringBuffer). Writes the header first when [header] is true.
void writeLevelReport(StringSink out, LevelReport report, {bool header = false}) {
  if (header) out.writeln(LevelReport.header);
  out.writeln(report.toLine());
}
