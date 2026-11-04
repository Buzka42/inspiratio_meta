import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/mic_levels.dart';
import 'package:illunis_client/input/utterance_gain.dart';
import 'package:illunis_client/input/voice_gate.dart';

// Synthetic buffers only: sines and seeded noise, no recorded speech.
const sr = 16000;

/// Sine at [peakDb] dBFS peak, [ms] long.
Int16List sine(double peakDb, int ms, {double hz = 220}) {
  final n = sr * ms ~/ 1000;
  final a = dbfsToAmp(peakDb) * kPcm16FullScale;
  return Int16List.fromList(
      [for (var i = 0; i < n; i++) (a * math.sin(2 * math.pi * hz * i / sr)).round()]);
}

/// Uniform noise at roughly [rmsDb] dBFS RMS.
Int16List noise(double rmsDb, int ms, {int seed = 1}) {
  final r = math.Random(seed);
  final n = sr * ms ~/ 1000;
  // Uniform in [-a, a] has RMS a / sqrt(3).
  final a = dbfsToAmp(rmsDb) * math.sqrt(3) * kPcm16FullScale;
  return Int16List.fromList([for (var i = 0; i < n; i++) ((r.nextDouble() * 2 - 1) * a).round()]);
}

Int16List cat(List<Int16List> parts) => Int16List.fromList([for (final p in parts) ...p]);

void main() {
  group('levels', () {
    test('sine peak and rms in dBFS', () {
      final s = sine(-40, 1000);
      expect(peakDbfs(s), closeTo(-40, 0.1));
      expect(rmsDbfs(s), closeTo(-43.01, 0.1)); // sine RMS = peak - 3.01 dB
    });

    test('silence measures at the floor value, not -infinity', () {
      expect(rmsDbfs(Int16List(1600)), kSilenceDbfs);
      expect(peakDbfs(Int16List(0)), kSilenceDbfs);
    });

    test('PCM16 bytes round trip, little endian', () {
      final s = Int16List.fromList([0, 1, -1, 32767, -32768, 1234]);
      final b = pcm16ToBytes(s);
      expect(b.sublist(2, 4), [1, 0]);
      expect(pcm16FromBytes(b), s);
      expect(pcm16FromBytes(Uint8List.fromList([1, 0, 9])).length, 1);
    });
  });

  group('normalisation', () {
    test('a whisper at -40 dBFS comes out at a usable level', () {
      final out = normaliseUtterance(sine(-40, 1000));
      expect(out.gainDb, greaterThan(15));
      expect(rmsDbfs(out.samples), closeTo(const WhisperTuning().targetRmsDbfs, 0.5));
      expect(peakDbfs(out.samples), lessThan(-1));
    });

    test('pure silence stays silent', () {
      final out = normaliseUtterance(Int16List(16000));
      expect(out.gainDb, 0);
      expect(out.samples.every((v) => v == 0), isTrue);
    });

    test('noise below the silence floor is never amplified', () {
      final quiet = noise(-70, 1000);
      final out = normaliseUtterance(quiet);
      expect(out.gainDb, 0);
      expect(out.samples, quiet);
    });

    test('gain is capped so the peak stays under -1 dBFS', () {
      // Spiky input: low RMS but a near-full-scale click.
      final s = cat([sine(-45, 900), Int16List.fromList([30000, -30000]), sine(-45, 100)]);
      final out = normaliseUtterance(s);
      expect(peakDbfs(out.samples), lessThan(-1));
    });

    test('loud input is brought under the ceiling, not clipped', () {
      final out = normaliseUtterance(sine(-0.1, 500));
      expect(out.gainDb, lessThan(0));
      expect(peakDbfs(out.samples), lessThan(-1));
    });

    test('gain never exceeds maxGainDb', () {
      const t = WhisperTuning(silenceFloorDbfs: -90, gateDbfs: -90);
      expect(normalisationGainDb(sine(-75, 500), tuning: t), t.maxGainDb);
    });
  });

  group('voice gate', () {
    test('threshold comes from the tuning, default is the constant', () {
      expect(const WhisperTuning().gateDbfs, kVoiceGateDbfs);
      final s = sine(-50, 600); // rms about -53
      expect(voicedMs(s, sr, const EnergyVad()), greaterThan(500));
      expect(voicedMs(s, sr, const EnergyVad(WhisperTuning(gateDbfs: -45))), 0);
    });

    test('room noise below the gate counts as no voice', () {
      expect(voicedMs(noise(-62, 1000), sr, const EnergyVad()), 0);
    });

    test('custom detector can replace the energy gate (Silero seam)', () {
      final s = sine(-30, 1000);
      expect(guardUtterance(s, sr, vad: _NeverVoiced()), GuardDrop.noVoice);
    });
  });

  group('hallucination guard', () {
    test('too short is dropped', () {
      expect(guardUtterance(sine(-30, 200), sr), GuardDrop.tooShort);
    });

    test('silence is dropped', () {
      expect(guardUtterance(Int16List(16000), sr), GuardDrop.belowFloor);
    });

    test('steady room noise is dropped', () {
      expect(guardUtterance(noise(-58, 1500), sr), GuardDrop.noVoice);
    });

    test('a whisper in a quiet room passes', () {
      final take = cat([noise(-65, 300), sine(-40, 800), noise(-65, 300, seed: 2)]);
      expect(guardUtterance(take, sr), isNull);
    });

    test('a click in silence does not reach the recogniser', () {
      final s = cat([Int16List(8000), sine(-10, 60), Int16List(8000)]);
      expect(guardUtterance(s, sr), isNot(isNull));
    });

    test('prepareUtterance returns null and reports the reason when dropped', () {
      final reasons = <GuardDrop>[];
      expect(prepareUtterance(Int16List(16000), sr, onDrop: reasons.add), isNull);
      expect(reasons, [GuardDrop.belowFloor]);
      final ok = prepareUtterance(sine(-40, 1000), sr);
      expect(ok, isNotNull);
      expect(rmsDbfs(ok!.samples), greaterThan(-25));
    });
  });

  group('level report rig', () {
    test('writes one tab-separated line with header', () {
      final out = StringBuffer();
      final r = levelReport(sine(-40, 1500), sr, label: 'whisper_30cm');
      writeLevelReport(out, r, header: true);
      final lines = out.toString().trim().split('\n');
      expect(lines.first, LevelReport.header);
      final f = lines[1].split('\t');
      expect(f, ['whisper_30cm', '1500', '-43.0', '-40.0', '1500', '-55.0']);
    });

    test('report carries no samples', () {
      final line = levelReport(sine(-20, 100), sr).toLine();
      expect(line.split('\t').length, 6);
    });
  });
}

class _NeverVoiced implements VoiceActivityDetector {
  @override
  int frameSamples(int sampleRate) => 480;

  @override
  List<bool> voicedFrames(Int16List samples, int sampleRate) =>
      List.filled((samples.length / 480).ceil(), false);
}
