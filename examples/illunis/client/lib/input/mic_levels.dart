/// Level measurement for 16-bit mono PCM, plus the Blade level report.
/// Pure functions. Never logs or stores audio; a report carries numbers only.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Full scale for signed 16-bit PCM (|sample| / this = 0..1).
const double kPcm16FullScale = 32768.0;

/// dBFS reported for a buffer with no energy at all (log of zero).
const double kSilenceDbfs = -120.0;

/// Little-endian PCM16 bytes (as sent on `illunis/mic/pcm`) to samples.
/// A trailing odd byte is dropped.
Int16List pcm16FromBytes(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final view = ByteData.sublistView(bytes);
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = view.getInt16(i * 2, Endian.little);
  }
  return out;
}

/// Samples back to little-endian PCM16 bytes.
Uint8List pcm16ToBytes(Int16List samples) {
  final out = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    out.setInt16(i * 2, samples[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Linear amplitude (0..1 of full scale) to dBFS, floored at [kSilenceDbfs].
double ampToDbfs(double amp) =>
    amp <= 0 ? kSilenceDbfs : math.max(kSilenceDbfs, 20 * math.log(amp) / math.ln10);

/// dBFS to linear amplitude (0..1 of full scale).
double dbfsToAmp(double dbfs) => math.pow(10, dbfs / 20).toDouble();

/// Largest |sample| over [start, end), as a fraction of full scale.
double peakAmp(Int16List s, [int start = 0, int? end]) {
  final e = end ?? s.length;
  var peak = 0;
  for (var i = start; i < e; i++) {
    final a = s[i].abs();
    if (a > peak) peak = a;
  }
  return peak / kPcm16FullScale;
}

/// RMS over [start, end), as a fraction of full scale.
double rmsAmp(Int16List s, [int start = 0, int? end]) {
  final e = end ?? s.length;
  if (e <= start) return 0;
  var sum = 0.0;
  for (var i = start; i < e; i++) {
    final v = s[i] / kPcm16FullScale;
    sum += v * v;
  }
  return math.sqrt(sum / (e - start));
}

double peakDbfs(Int16List s) => ampToDbfs(peakAmp(s));
double rmsDbfs(Int16List s) => ampToDbfs(rmsAmp(s));

/// Numbers for one buffer, for comparing takes on the Blade.
class LevelReport {
  const LevelReport({
    required this.label,
    required this.durationMs,
    required this.rmsDbfs,
    required this.peakDbfs,
    required this.voicedMs,
    required this.gateDbfs,
  });

  final String label;
  final int durationMs;
  final double rmsDbfs;
  final double peakDbfs;

  /// Time the voice gate counted as speech (see voice_gate.dart).
  final int voicedMs;

  /// Gate threshold in force when the report was made.
  final double gateDbfs;

  /// One line, tab separated, stable field order:
  /// label, duration_ms, rms_dbfs, peak_dbfs, voiced_ms, gate_dbfs.
  String toLine() => [
        label,
        '$durationMs',
        rmsDbfs.toStringAsFixed(1),
        peakDbfs.toStringAsFixed(1),
        '$voicedMs',
        gateDbfs.toStringAsFixed(1),
      ].join('\t');

  static const header = 'label\tduration_ms\trms_dbfs\tpeak_dbfs\tvoiced_ms\tgate_dbfs';
}

/// Duration of [sampleCount] samples at [sampleRate], in whole milliseconds.
int durationMs(int sampleCount, int sampleRate) =>
    sampleRate <= 0 ? 0 : (sampleCount * 1000) ~/ sampleRate;
