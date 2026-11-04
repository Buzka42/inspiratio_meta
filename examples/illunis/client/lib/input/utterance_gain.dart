/// Per-utterance normalisation for whispered input. Capture runs with AGC
/// off, so a whisper arrives quiet; one capped gain per utterance lifts it
/// before decoding. Pure functions.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mic_levels.dart';
import 'voice_gate.dart';

class NormalisedUtterance {
  const NormalisedUtterance(this.samples, this.gainDb);
  final Int16List samples;

  /// Gain applied, in dB (0 when the input was left as is).
  final double gainDb;
}

/// Gain in dB for [samples]: aims RMS at [WhisperTuning.targetRmsDbfs],
/// never above [WhisperTuning.maxGainDb], and never so high that the peak
/// reaches [WhisperTuning.peakCeilingDbfs]. Below the silence floor the
/// answer is 0 dB: silence is never amplified. Loud input may get a
/// negative gain so its peak comes under the ceiling.
double normalisationGainDb(Int16List samples, {WhisperTuning tuning = const WhisperTuning()}) {
  final rms = rmsDbfs(samples);
  final peak = peakDbfs(samples);
  if (rms < tuning.silenceFloorDbfs) {
    // Still keep a clipped-hot buffer under the ceiling (never true for silence).
    return peak >= tuning.peakCeilingDbfs ? tuning.peakCeilingDbfs - peak : 0;
  }
  final toTarget = tuning.targetRmsDbfs - rms;
  final toCeiling = tuning.peakCeilingDbfs - peak;
  return math.min(math.min(toTarget, tuning.maxGainDb), toCeiling);
}

/// Applies [normalisationGainDb] once to the whole utterance.
NormalisedUtterance normaliseUtterance(Int16List samples,
    {WhisperTuning tuning = const WhisperTuning()}) {
  final db = normalisationGainDb(samples, tuning: tuning);
  if (db == 0) return NormalisedUtterance(Int16List.fromList(samples), 0);
  final g = dbfsToAmp(db);
  // Strict ceiling in sample units, so rounding can never land on it.
  final limit = (dbfsToAmp(tuning.peakCeilingDbfs) * kPcm16FullScale).floor() - 1;
  final out = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    out[i] = (samples[i] * g).round().clamp(-limit, limit);
  }
  return NormalisedUtterance(out, db);
}

/// Guard, then normalise. Null when the guard drops the utterance; the
/// recogniser must never see a dropped one.
NormalisedUtterance? prepareUtterance(
  Int16List samples,
  int sampleRate, {
  WhisperTuning tuning = const WhisperTuning(),
  VoiceActivityDetector? vad,
  void Function(GuardDrop reason)? onDrop,
}) {
  final drop = guardUtterance(samples, sampleRate, tuning: tuning, vad: vad);
  if (drop != null) {
    onDrop?.call(drop);
    return null;
  }
  return normaliseUtterance(samples, tuning: tuning);
}
