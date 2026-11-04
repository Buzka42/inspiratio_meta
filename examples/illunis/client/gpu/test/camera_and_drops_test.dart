import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

void main() {
  const cam = WaterCamera();
  const aspect = 1080 / 2400;

  test('the screen centre looks at the water at the pitch angle', () {
    final hit = cam.planeHit(const Offset(0.5, 0.5), aspect)!;
    expect(hit.dx, closeTo(0, 1e-9));
    expect(hit.dy, closeTo(cam.height / math.tan(cam.pitch), 1e-9));
  });

  test('the sim domain covers every visible water point up to the far cap', () {
    for (final pitch in [45.0, 60.0, 90.0]) {
      final c = WaterCamera(pitch: pitch * math.pi / 180);
      final d = c.simDomain(aspect, farCap: 6);
      for (var y = 0; y <= 20; y++) {
        for (var x = 0; x <= 20; x++) {
          final hit = c.planeHit(Offset(x / 20, y / 20), aspect);
          if (hit == null || hit.distance > 6) continue;
          expect(d.contains(hit), isTrue, reason: 'pitch $pitch at ($x, $y): $hit not in $d');
        }
      }
    }
  });

  test('sim resolution keeps the texel budget and square texels', () {
    final d = cam.simDomain(aspect);
    final (w, h) = simResolution(d, texelBudget: 786432);
    expect(w * h, closeTo(786432, 786432 * 0.02));
    expect((d.width / w) / (d.height / h), closeTo(1, 0.02));
    final (w2, h2) = simResolution(const Rect.fromLTRB(0, 0, 100, 1), texelBudget: 1 << 20);
    expect(math.max(w2, h2), lessThanOrEqualTo(2048));
  });

  test('worldToCell matches the shader mapping (cell centres on integers)', () {
    const d = Rect.fromLTRB(-1, 0, 1, 4);
    expect(worldToCell(const Offset(-1, 0), d, 100, 200), const Offset(-0.5, -0.5));
    expect(worldToCell(const Offset(1, 4), d, 100, 200), const Offset(99.5, 199.5));
    expect(worldToCell(const Offset(0, 2), d, 100, 200), const Offset(49.5, 99.5));
  });

  test('walker pulses at once, then once per period', () {
    final s = DropScheduler(ambientRate: 0, loudRate: 0);
    const w = Offset(10, 10);
    expect(s.next(1 / 120, w, 0, 64, 64, 0.01), hasLength(1));
    var pulses = 0;
    for (var i = 0; i < 120 * 9; i++) {
      pulses += s.next(1 / 120, w, 0, 64, 64, 0.01).length;
    }
    expect(pulses, 10); // 9 s at a 0.9 s period
    expect(s.next(1 / 120, null, 0, 64, 64, 0.01), isEmpty); // walker off the water
  });

  test('ambient drops follow the rate, rise with loudness, never exceed the cap', () {
    int count(double loud) {
      final s = DropScheduler(seed: 1, walkerStrength: 0);
      var n = 0;
      for (var i = 0; i < 120 * 20; i++) {
        final drops = s.next(1 / 120, null, loud, 64, 64, 0.01);
        expect(drops.length, lessThanOrEqualTo(maxDropsPerStep));
        for (final d in drops) {
          expect(d.x, inInclusiveRange(0, 64));
          expect(d.y, inInclusiveRange(0, 64));
        }
        n += drops.length;
      }
      return n;
    }

    expect(count(0), closeTo(0.4 * 20, 1));
    expect(count(1), closeTo(5.4 * 20, 2));
  });

  test('uniform packing follows the shader block order', () {
    final sim = packSimInfo(4, 8, const WaveParams(), const [Drop(1, 2, 3, 4)]);
    expect(sim, hasLength(24));
    expect(sim.sublist(0, 4), [4, 8, 0.25, 0.125]);
    expect(sim.sublist(8, 12), [1, 2, 3, 4]);
    expect(sim.sublist(12), everyElement(0));
    final f = packFrameInfo(
        width: 1080, height: 2400, time: 2, loudness: 3, camera: cam, vignette: 1,
        domain: const Rect.fromLTRB(-1, 0, 1, 2), simW: 10, simH: 20, heightScale: 0.5, detail: 1);
    expect(f, hasLength(72));
    expect(f[16], 1); // stillness defaults to the rough look
    expect(f[3], 1); // loudness clamped
    expect(f.sublist(8, 12), [-1, 0, 1, 2]);
    expect(f.sublist(20), everyElement(0)); // no per-pixel moon or stars
    final g = packFrameInfo(
        width: 1080, height: 2400, time: 2, loudness: 0, camera: cam, vignette: 1,
        domain: const Rect.fromLTRB(-1, 0, 1, 2), simW: 10, simH: 20, heightScale: 0.5, detail: 1,
        starGrid: (1024, 256), pixelRad: 5e-4, grain: 0.003);
    expect(g.sublist(32, 36), [1024, 256, closeTo(5e-4, 1e-9), 0]);
    expect(g[31], closeTo(0.003, 1e-9));
  });

  test('day uniforms: off at night, wind offsets wrapped and against the wind', () {
    Float32List pack({SkySun? sun, SkyClouds? clouds, double time = 0}) => packFrameInfo(
        width: 1080, height: 2400, time: time, loudness: 0, camera: cam, vignette: 1,
        domain: const Rect.fromLTRB(-1, 0, 1, 2), simW: 10, simH: 20, heightScale: 0.5, detail: 1,
        sun: sun, clouds: clouds);
    const sun = SkySun(
        dir: (0, 0.6, 0.8), angularRadius: 0.00465, colour: (1, 0.9, 0.8), intensity: 0.7, dayFade: 1);
    const clouds = SkyClouds(windVelocity: (60, -30), speed: 2, tier: 1, coverage: 0.5);
    expect(pack(clouds: clouds).sublist(36), everyElement(0)); // no sun: no day block
    expect(pack(sun: const SkySun(dir: (0, 1, 0), angularRadius: 0.00465, colour: (1, 1, 1),
            intensity: 1, dayFade: 0), clouds: clouds).sublist(36), everyElement(0));
    final f = pack(sun: sun, clouds: clouds, time: 100);
    expect(f.sublist(36, 40), [0, closeTo(0.6, 1e-6), closeTo(0.8, 1e-6), closeTo(0.00465, 1e-9)]);
    expect(f.sublist(40, 44), [1, closeTo(0.9, 1e-6), closeTo(0.8, 1e-6), closeTo(0.7, 1e-6)]);
    expect(f.sublist(44, 48), [1, 1, closeTo(0.6, 1e-6), closeTo(1 / 6000, 1e-9)]);
    expect(f.sublist(48, 52), [0.5, 1, 0.25, 0]);
    // 60 m/s x 2 x 100 s = 12 km = 2 tiles in x: offset 0; -30 x 2 x 100 =
    // -6 km = -1 tile in z: offset 0. Detail at 3.7 x 1.3 of that, wrapped.
    expect(f[52], closeTo(0, 1e-6));
    expect(f[53], closeTo(0, 1e-6));
    final o = clouds.layerOffsets(25); // 3 km in x, -1.5 km in z
    expect(o[0], closeTo(0.5, 1e-9));
    expect(o[1], closeTo(0.25, 1e-9));
    expect(o.every((v) => v >= 0 && v < 1), isTrue);
    expect(o[2], closeTo((-0.5 * 3.7 * 1.3) % 1.0, 1e-9));
    expect(f.sublist(64, 72), everyElement(0)); // no night light
  });

  test('night cloud uniforms: the layer and its wind without a sun, moon in nightMoon', () {
    Float32List pack({SkySun? sun, SkyClouds? clouds, double time = 0}) => packFrameInfo(
        width: 1080, height: 2400, time: time, loudness: 0, camera: cam, vignette: 1,
        domain: const Rect.fromLTRB(-1, 0, 1, 2), simW: 10, simH: 20, heightScale: 0.5, detail: 1,
        sun: sun, clouds: clouds);
    const night = CloudNight(moonDir: (0, 0.6, 0.8), moonLight: 0.7, fade: 1);
    const clouds = SkyClouds(windVelocity: (4, 0), coverage: 0.5, night: night);
    const set = SkySun(dir: (0, -0.3, 0.95), angularRadius: 0.00465, colour: (1, 0.5, 0.2),
        intensity: 0, dayFade: 0);
    final f = pack(sun: set, clouds: clouds, time: 750);
    expect(f.length, 72);
    expect(f.sublist(36, 46), everyElement(0)); // sun, sunLight, dayFade and tier off ...
    expect(f.sublist(48, 51), [0.5, 1, 0.25]); // ... but the cloud layer is there
    // 4 m/s x 750 s = 3 km = half a tile, against the wind.
    expect(f[52], closeTo(0.5, 1e-6));
    expect(f.sublist(64, 72), [0, closeTo(0.6, 1e-6), closeTo(0.8, 1e-6), closeTo(0.7, 1e-6), 1, 0, 0, 0]);
    // Without a sun at all the night layer still packs; fade 0 turns it off.
    expect(pack(clouds: clouds).sublist(64, 68)[3], closeTo(0.7, 1e-6));
    const off = SkyClouds(night: CloudNight(moonLight: 1, fade: 0));
    expect(pack(sun: set, clouds: off).sublist(36), everyElement(0));
    expect(clouds, const SkyClouds(windVelocity: (4, 0), coverage: 0.5, night: night));
    expect(clouds == const SkyClouds(windVelocity: (4, 0), coverage: 0.5), isFalse);
  });
}
