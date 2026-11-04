// Cloud plates without a GPU: the fallback choice, the loader's failure
// path, the plate offsets (mirror period 2) and the uniform packing.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, Uint8List> files;
  @override
  Future<ByteData> load(String key) async {
    final f = files[key];
    if (f == null) throw StateError('missing $key');
    return ByteData.sublistView(f);
  }
}

// A 1x1 opaque black PNG.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0x60, 0x60, 0x60, 0x00,
  0x00, 0x00, 0x04, 0x00, 0x01, 0x27, 0x34, 0x27, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
  0x44, 0xae, 0x42, 0x60, 0x82,
]);

Float32List _pack({SkySun? sun, SkyClouds? clouds, int plateSize = 0, double time = 0}) => packFrameInfo(
      width: 100,
      height: 200,
      time: time,
      loudness: 0,
      camera: const WaterCamera(),
      vignette: 0,
      domain: const Rect.fromLTRB(0, 0, 1, 1),
      simW: 8,
      simH: 8,
      heightScale: 1,
      detail: 0,
      sun: sun,
      clouds: clouds,
      cloudPlateSize: plateSize,
    );

const _sun = SkySun(dir: (0, 0.5, 0.866), angularRadius: 0.00465, colour: (1, 1, 1), intensity: 1, dayFade: 1);

void main() {
  test('plates only when both load; otherwise procedural noise', () {
    expect(cloudSourceFor(plateA: true, plateB: true), CloudSource.plates);
    expect(cloudSourceFor(plateA: true, plateB: false), CloudSource.procedural);
    expect(cloudSourceFor(plateA: false, plateB: true), CloudSource.procedural);
    expect(cloudSourceFor(plateA: false, plateB: false), CloudSource.procedural);
  });

  test('a plate is usable when square and at least 2048 texels', () {
    expect(plateUsable(2048, 2048), isTrue);
    expect(plateUsable(4096, 4096), isTrue);
    expect(plateUsable(1024, 1024), isFalse);
    expect(plateUsable(2048, 1024), isFalse);
  });

  test('the loader returns null when either plate is missing, plates when both decode', () async {
    final both = _Bundle({'a.png': _png, 'b.png': _png});
    final oneMissing = _Bundle({'a.png': _png});
    final garbage = _Bundle({'a.png': _png, 'b.png': Uint8List.fromList([1, 2, 3])});
    Future<CloudPlates?> load(AssetBundle b, List<List<String>> keys) =>
        CloudPlates.load(b, assets: keys, minSide: 1);
    expect(await load(oneMissing, [['a.png'], ['b.png']]), isNull);
    expect(await load(garbage, [['a.png'], ['b.png']]), isNull);
    expect(await load(both, [['a.png']]), isNull);
    // Too small for the default 2048 minimum: procedural.
    expect(await CloudPlates.load(both, assets: [['a.png'], ['b.png']]), isNull);
    final p = await load(both, [['a.png'], ['b.png']]);
    expect(p, isNotNull);
    expect(p!.a.width, 1);
    p.dispose();
    // A missing larger candidate falls through to the next key.
    final q = await load(both, [['a_4k.png', 'a.png'], ['b_4k.png', 'b.png']]);
    expect(q, isNotNull);
    q!.dispose();
  });

  test('the default plates prefer a 4k plate, then the two approved cumulus plates', () {
    expect(CloudPlates.defaultAssets.map((k) => k.last),
        ['assets/clouds/cumulus_02.png', 'assets/clouds/cumulus_06.png']);
    expect(CloudPlates.defaultAssets.every((k) => k.first.contains('_4k')), isTrue);
  });

  test('plate offsets: four samples, each wrapped on 2 (the mirror period), at its own rate', () {
    const c = SkyClouds(windVelocity: (10, -5));
    final o0 = c.plateOffsets(0);
    expect(o0.length, 8);
    for (var i = 0; i < 4; i++) {
      final ph = SkyClouds.plateLayers[i].phase;
      expect(o0[2 * i], closeTo(ph.$1, 1e-12));
      expect(o0[2 * i + 1], closeTo(ph.$2, 1e-12));
    }
    // 600 s at 10 m/s = 6 km = one plate: A1 has moved 1, not wrapped back.
    final o1 = c.plateOffsets(600);
    expect(o1[0], closeTo((0.37 - 1.0) % 2.0, 1e-12));
    expect(o1[1], closeTo((0.21 + 0.5) % 2.0, 1e-12)); // -5 m/s: +0.5 against the wind
    expect(c.plateOffsets(1200)[0], closeTo(0.37, 1e-9));
    for (final t in [1.0, 77.0, 599.0, 1234.5, 99999.0]) {
      for (final v in c.plateOffsets(t)) {
        expect(v, inInclusiveRange(0.0, 2.0));
      }
    }
    // No two samples share a scale, an angle or a phase.
    final l = SkyClouds.plateLayers;
    expect(l.map((e) => e.scale).toSet().length, 4);
    expect(l.map((e) => e.angle).toSet().length, 4);
    expect(l.map((e) => e.phase).toSet().length, 4);
  });

  test('a rotated sample drifts with the wind in its own frame', () {
    const l = PlateLayer(scale: 2, angle: math.pi / 2, drift: 0.5, phase: (0, 0));
    // Rotating (dx, 0) by 90 degrees gives (0, dx); times scale x drift = 1.
    final o = l.offset(0.25, 0);
    // Compare on the mirror period: 2.0 and 0.0 are the same offset.
    double circ(double a, double b) => ((a - b + 1) % 2.0 - 1).abs();
    expect(circ(o[0], 0), lessThan(1e-12));
    expect(circ(o[1], 1.75), lessThan(1e-12));
  });

  test('packing: plates set cloud.w to the plate side and carry the four offsets', () {
    const c = SkyClouds(windVelocity: (10, 0));
    final proc = _pack(sun: _sun, clouds: c, time: 300);
    final plate = _pack(sun: _sun, clouds: c, plateSize: 2048, time: 300);
    expect(proc.length, 72);
    // cloud = 48..51, wind = 52..55, cirrus = 56..59, plates = 60..63.
    expect(proc[51], 0);
    expect(plate[51], 2048);
    final lo = c.layerOffsets(300), po = c.plateOffsets(300);
    expect(proc.sublist(52, 64), [for (final v in [...lo, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]) closeTo(v, 1e-6)]);
    expect(plate.sublist(52, 54), [closeTo(po[0], 1e-6), closeTo(po[1], 1e-6)]); // A1
    expect(plate.sublist(54, 58), [for (final v in lo.sublist(2)) closeTo(v, 1e-6)]); // detail, cirrus
    expect(plate.sublist(58, 60), [closeTo(po[4], 1e-6), closeTo(po[5], 1e-6)]); // B1
    expect(plate.sublist(60, 64), [for (final i in [2, 3, 6, 7]) closeTo(po[i], 1e-6)]); // A2, B2
  });

  test('packing: night and no clouds ignore plates', () {
    final night = _pack(sun: const SkySun(dir: (0, 0.5, 0.866), angularRadius: 0.00465,
        colour: (1, 1, 1), intensity: 1, dayFade: 0), clouds: const SkyClouds(), plateSize: 2048);
    expect(night.sublist(36), everyElement(0));
    final noClouds = _pack(sun: _sun, plateSize: 2048);
    expect(noClouds[51], 0);
  });
}
