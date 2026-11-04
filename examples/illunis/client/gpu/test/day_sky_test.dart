// Day sky in the surface pass: the per-pixel sun, the moving clouds and the
// generated cloud texture. Needs Impeller and Flutter GPU in the tester
// (flutter test --enable-impeller --enable-flutter-gpu); skipped otherwise.
//
// Set ILLUNIS_DAY_PNG=<path.png> to also write a full-size day frame there
// (the "host frame" used for the visual check).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

import 'day_sky_fixture.dart';

Future<GpuWaterRenderer> _make(ui.Image sky) =>
    GpuWaterRenderer.create(sky: sky, texelBudget: 4096, asset: 'assets/water.shaderbundle');

Future<Uint8List> _frame(GpuWaterRenderer r, {double time = 0}) async {
  ui.Image? img;
  while ((img = r.frame(0, time: time, vignette: 0, detail: 0, stillness: 0)) == null) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return rgba(img!);
}

Future<ui.Image> _flatSky(int r, int g, int b) {
  const w = 64, h = 32;
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px.setAll(i * 4, [r, g, b, 255]);
  }
  return imageFromRgba(px, w, h);
}

double _luma(Uint8List b, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return 0.2126 * b[i] + 0.7152 * b[i + 1] + 0.0722 * b[i + 2];
}

void main() {
  final skip = !gpuAvailable();

  test('night: a sun at dayFade 0 with clouds draws the frame without them, bit for bit', () async {
    final r = await _make(await _flatSky(20, 25, 40));
    const w = 270, h = 600;
    r.resize(w, h);
    final plain = await _frame(r, time: 3);
    r
      ..setSun(noonSun(dirFrom(0, 60), dayFade: 0))
      ..setClouds(const SkyClouds(coverage: 0.9, windVelocity: (20, 5), tier: 1));
    final night = await _frame(r, time: 3);
    expect(night, orderedEquals(plain));
  }, skip: skip);

  test('night clouds: darker than the night sky, moonlit near the moon, drifting', () async {
    final r = await _make(await _flatSky(20, 25, 40));
    const w = 270, h = 600;
    r.resize(w, h);
    final plain = await _frame(r, time: 3);
    const moon = (0.0, 0.5, 0.866); // 30 degrees up, straight ahead
    final set = noonSun(dirFrom(0, -30), dayFade: 0);
    r
      ..setSun(set)
      ..setClouds(const SkyClouds(coverage: 0.9, windVelocity: (20, 5), tier: 0,
          night: CloudNight(fade: 1)));
    final dark = await _frame(r, time: 3);
    r.setClouds(const SkyClouds(coverage: 0.9, windVelocity: (20, 5), tier: 0,
        night: CloudNight(moonDir: moon, moonLight: 1, fade: 1)));
    final lit = await _frame(r, time: 3);
    final drift = await _frame(r, time: 300);
    double mean(Uint8List b) {
      var s = 0.0;
      for (var y = h ~/ 2; y < h; y++) {
        for (var x = 0; x < w; x++) {
          s += _luma(b, w, x, y);
        }
      }
      return s / (w * (h - h ~/ 2));
    }
    expect(mean(dark), lessThan(mean(plain))); // no moon: clouds darken the sky
    expect(mean(lit), greaterThan(mean(dark))); // the moon lights them
    expect(drift, isNot(orderedEquals(lit))); // the wind moves them
  }, skip: skip);

  test('day: the sun disc sits at its reflected direction, brighter at the centre than the limb',
      () async {
    final r = await _make(await daySky(dirFrom(0, 60), w: 512, h: 256));
    const w = 1080, h = 2400;
    r.resize(w, h);
    // Straight ahead at 60 degrees: the screen centre on calm water.
    r.setSun(noonSun(dirFrom(0, 60)));
    final b = await _frame(r);
    var peak = 0.0;
    for (var y = h ~/ 2 - 60; y < h ~/ 2 + 60; y++) {
      for (var x = w ~/ 2 - 60; x < w ~/ 2 + 60; x++) {
        peak = math.max(peak, _luma(b, w, x, y));
      }
    }
    var sx = 0.0, sy = 0.0, n = 0;
    for (var y = h ~/ 2 - 60; y < h ~/ 2 + 60; y++) {
      for (var x = w ~/ 2 - 60; x < w ~/ 2 + 60; x++) {
        if (_luma(b, w, x, y) > peak - 12) {
          sx += x;
          sy += y;
          n++;
        }
      }
    }
    final cx = sx / n, cy = sy / n;
    // Radius 0.00465 rad over 1.2 / 2400 rad per pixel: about 9.3 px.
    final centre = _luma(b, w, cx.round(), cy.round());
    final limb = (_luma(b, w, (cx + 8).round(), cy.round()) + _luma(b, w, (cx - 8).round(), cy.round())) / 2;
    final out = _luma(b, w, (cx + 40).round(), cy.round());
    printOnFailure('peak=$peak centre=($cx, $cy) n=$n lumas $centre / $limb / $out');
    expect((cx - w / 2).abs(), lessThan(2));
    expect((cy - h / 2).abs(), lessThan(2));
    expect(centre, greaterThan(235));
    expect(centre, greaterThan(limb + 3));
    expect(limb, greaterThan(out + 40));
  }, skip: skip);

  test('sun colour follows extinction: a 1-degree sun is red, a 25-degree sun near white, neither clips flat',
      () async {
    // Colours and strengths from the app's daySun for Warsaw, 2026-10-24,
    // at 07:30 and 13:00 CEST; the disc is placed at the screen centre.
    const w = 1080, h = 2400;
    late GpuWaterRenderer r;
    Future<(List<int>, double, double)> disc((double, double, double) colour, double intensity) async {
      r.setSun(SkySun(dir: dirFrom(0, 60), angularRadius: 0.00465, colour: colour,
          intensity: intensity, dayFade: 1));
      final b = await _frame(r);
      final i = (h ~/ 2 * w + w ~/ 2) * 4;
      return ([b[i], b[i + 1], b[i + 2]], _luma(b, w, w ~/ 2, h ~/ 2), _luma(b, w, w ~/ 2 + 8, h ~/ 2));
    }

    // A 1-degree sun sits in a dim dawn sky; the 13:00 one in a day blue.
    r = await _make(await _flatSky(45, 45, 70));
    r.resize(w, h);
    final (low, _, _) = await disc((1.0, 0.07912, 0.00045), 0.13998);
    r = await _make(await _flatSky(110, 150, 210));
    r.resize(w, h);
    final (high, cHigh, limbHigh) = await disc((1.0, 0.87277, 0.66160), 0.88435);
    printOnFailure('07:30 centre rgb $low; 13:00 centre rgb $high, luma $cHigh, limb $limbHigh');
    expect(low[0], greaterThan(low[1] + 50)); // red
    expect(low[0], greaterThan(low[2] + 50));
    expect(high[0] - high[2], lessThan(40)); // near white, slightly warm
    expect(high[0], greaterThanOrEqualTo(high[2]));
    expect(high.every((c) => c < 255), isTrue); // not clipped
    expect(cHigh, greaterThan(limbHigh + 3)); // limb darkening survives
  }, skip: skip);

  test('clouds drift with the wind: 10 s later they have moved downwind', () async {
    final sun = dirFrom(35, 40);
    final r = await _make(await daySky(sun, w: 512, h: 256));
    const w = 270, h = 600;
    r.resize(w, h);
    r.setSun(noonSun(sun));
    final clear = await _frame(r);
    r.setClouds(const SkyClouds(coverage: 0.5, windVelocity: (10, 0), shadow: 0));
    final a = await _frame(r, time: 0);
    final b = await _frame(r, time: 10);
    int diff(Uint8List p, Uint8List q, int i) =>
        (p[i] - q[i]).abs() + (p[i + 1] - q[i + 1]).abs() + (p[i + 2] - q[i + 2]).abs();
    var cloudA = 0, cloudB = 0, moved = 0, stray = 0;
    for (var i = 0; i < a.length; i += 4) {
      final inA = diff(a, clear, i) > 3, inB = diff(b, clear, i) > 3;
      if (inA) cloudA++;
      if (inB) cloudB++;
      if (diff(a, b, i) > 3) {
        moved++;
        if (!inA && !inB) stray++;
      }
    }
    printOnFailure('cloud px a=$cloudA b=$cloudB moved=$moved stray=$stray');
    expect(cloudA, greaterThan(w * h * 0.1)); // there are clouds
    expect(moved, greaterThan(w * h * 0.03)); // and they moved
    expect(stray, 0); // nothing changed outside them
    expect(cloudB / cloudA, closeTo(1, 0.3)); // the same structure, moved

    // Direction: +x wind moves the pattern right on screen. Best horizontal
    // shift of the cloud signal over a band at the screen centre; about 100 m
    // at the plane, ~3.5 m per pixel there.
    double sig(Uint8List p, int x, int y) => _luma(p, w, x, y) - _luma(clear, w, x, y);
    var best = 0, bestErr = double.infinity;
    for (var s = -60; s <= 60; s++) {
      var err = 0.0;
      for (var y = h ~/ 2 - 40; y < h ~/ 2 + 40; y += 2) {
        for (var x = 70; x < w - 70; x++) {
          final e = sig(b, x + s, y) - sig(a, x, y);
          err += e * e;
        }
      }
      if (err < bestErr) {
        bestErr = err;
        best = s;
      }
    }
    printOnFailure('best shift $best px');
    expect(best, inInclusiveRange(12, 50));
  }, skip: skip);

  test('the generated cloud texture tiles (edges continue across the wrap)', () async {
    final r = await _make(await _flatSky(120, 160, 220));
    const n = GpuWaterRenderer.cloudTextureSize;
    final t = await rgba(r.debugCloudImage());
    expect(t.length, n * n * 4);
    for (var c = 0; c < 3; c++) {
      double meanDiff(int Function(int) i0, int Function(int) i1) {
        var s = 0.0;
        for (var k = 0; k < n; k++) {
          s += (t[i0(k) + c] - t[i1(k) + c]).abs();
        }
        return s / n;
      }

      int at(int x, int y) => (y * n + x) * 4;
      final seamX = meanDiff((k) => at(0, k), (k) => at(n - 1, k));
      final seamY = meanDiff((k) => at(k, 0), (k) => at(k, n - 1));
      final innerX = meanDiff((k) => at(n ~/ 2, k), (k) => at(n ~/ 2 - 1, k));
      final innerY = meanDiff((k) => at(k, n ~/ 2), (k) => at(k, n ~/ 2 - 1));
      final far = meanDiff((k) => at(0, k), (k) => at(n ~/ 2, k));
      var sum = 0.0, over = 0;
      for (var i = c; i < t.length; i += 4) {
        sum += t[i];
        if (t[i] > 0.55 * 255) over++;
      }
      printOnFailure('ch $c seam $seamX/$seamY inner $innerX/$innerY far $far '
          'mean ${(sum / (n * n) / 255).toStringAsFixed(3)} over55 ${(over / (n * n)).toStringAsFixed(3)}');
      // Across the wrap the texture changes no more than between neighbours.
      expect(seamX, lessThan(innerX * 1.5 + 1));
      expect(seamY, lessThan(innerY * 1.5 + 1));
      expect(far, greaterThan(innerX * 3 + 3)); // and it is not flat
    }
  }, skip: skip);

  test('a cloud is brighter on the side facing the sun', () async {
    // One soft blob where the screen centre's reflected ray meets the cloud
    // plane: rd = (0, sin 60, cos 60), q = rd.xz / rd.y * 1500 / 6000.
    const n = 256;
    final q0 = 0.25 / math.tan(math.pi / 3);
    final px = Uint8List(n * n * 4);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        double wrap(double v) => v - v.roundToDouble();
        final dx = wrap((x + 0.5) / n), dy = wrap((y + 0.5) / n - q0);
        final v = math.exp(-(dx * dx + dy * dy) / (2 * 0.035 * 0.035));
        px.setAll((y * n + x) * 4, [(v * 255).round(), 128, 0, 255]);
      }
    }
    final blob = await imageFromRgba(px, n, n);
    final r = await _make(await _flatSky(110, 150, 210));
    const w = 540, h = 1200;
    r.resize(w, h);
    r
      ..setCloudTexture(blob)
      ..setClouds(const SkyClouds(coverage: 0.6, shadow: 0));
    Future<(double, double)> sides(double sunAz) async {
      r.setSun(noonSun(dirFrom(sunAz, 30)));
      final b = await _frame(r);
      double band(int x0) {
        var s = 0.0;
        for (var y = h ~/ 2 - 10; y <= h ~/ 2 + 10; y++) {
          for (var x = x0 - 5; x <= x0 + 5; x++) {
            s += _luma(b, w, x, y);
          }
        }
        return s / (21 * 11);
      }

      return (band(w ~/ 2 - 110), band(w ~/ 2 + 110));
    }

    final (l1, r1) = await sides(90); // sun to the right
    final (l2, r2) = await sides(-90); // sun to the left
    printOnFailure('sun right: $l1 | $r1   sun left: $l2 | $r2');
    expect(r1, greaterThan(l1 + 8));
    expect(l2, greaterThan(r2 + 8));
  }, skip: skip);

  // --- Cloud plates -------------------------------------------------------
  // Each plate is sampled at two scales and rotations with a half-offset
  // blend, so these tests check outcomes, not where one texel lands.
  const pn = 256;

  // A plate of one grey level (alpha 255).
  Future<ui.Image> solidPlate(int c) {
    final px = Uint8List(pn * pn * 4);
    for (var i = 0; i < pn * pn; i++) {
      px.setAll(i * 4, [c, c, c, 255]);
    }
    return imageFromRgba(px, pn, pn);
  }

  // Brightness rises left to right, 0 to 255: a hard jump wherever a sample
  // wraps with repeat addressing (no mirror, no blend).
  Future<ui.Image> rampPlate() {
    final px = Uint8List(pn * pn * 4);
    for (var y = 0; y < pn; y++) {
      for (var x = 0; x < pn; x++) {
        final c = (255 * (x + 0.5) / pn).round();
        px.setAll((y * pn + x) * 4, [c, c, c, 255]);
      }
    }
    return imageFromRgba(px, pn, pn);
  }

  double centreLuma(Uint8List b, int w, int h) {
    var s = 0.0;
    for (var y = h ~/ 2 - 4; y <= h ~/ 2 + 4; y++) {
      for (var x = w ~/ 2 - 4; x <= w ~/ 2 + 4; x++) {
        s += _luma(b, w, x, y);
      }
    }
    return s / 81;
  }

  test('night: with plates set, a sun at dayFade 0 still draws the night frame bit for bit', () async {
    final r = await _make(await _flatSky(20, 25, 40));
    const w = 270, h = 600;
    r.resize(w, h);
    final plain = await _frame(r, time: 3);
    expect(r.setCloudPlates(CloudPlates(await rampPlate(), await solidPlate(200))), CloudSource.plates);
    r
      ..setSun(noonSun(dirFrom(0, 60), dayFade: 0))
      ..setClouds(const SkyClouds(coverage: 0.9, windVelocity: (20, 5), tier: 1));
    expect(await _frame(r, time: 3), orderedEquals(plain));
  }, skip: skip);

  test('plates: brightness is opacity (black = clear sky, white = cloud)', () async {
    final r = await _make(await _flatSky(110, 150, 210));
    const w = 270, h = 600;
    r.resize(w, h);
    r.setSun(noonSun(dirFrom(90, 30)));
    final clear = await _frame(r);
    r.setClouds(const SkyClouds(coverage: 0.5, shadow: 0));
    expect(r.setCloudPlates(CloudPlates(await solidPlate(0), await solidPlate(0))), CloudSource.plates);
    final black = await _frame(r);
    // The lower 60% of the screen (reflected rays well above the horizon):
    // higher up, the far field fades toward a mean thickness by design (no
    // mipmaps), so black plates are not clear there.
    var maxDiff = 0;
    for (var i = (h * 0.4).round() * w * 4; i < clear.length; i++) {
      if (i % 4 == 3) continue;
      maxDiff = math.max(maxDiff, (black[i] - clear[i]).abs());
    }
    printOnFailure('black plates max channel diff vs clear $maxDiff');
    expect(maxDiff, lessThanOrEqualTo(1)); // the linear round trip only

    r.setCloudPlates(CloudPlates(await solidPlate(255), await solidPlate(0)));
    final cloud = await _frame(r);
    printOnFailure('centre luma clear ${centreLuma(clear, w, h)} cloud ${centreLuma(cloud, w, h)}');
    expect(centreLuma(cloud, w, h), greaterThan(centreLuma(clear, w, h) + 20));

    // Back to procedural: null plates.
    expect(r.setCloudPlates(null), CloudSource.procedural);
    expect(r.cloudSource, CloudSource.procedural);
  }, skip: skip);

  test('plates show no hard seam: mirror wrap plus the half-offset blend keep a ramp continuous',
      () async {
    final r = await _make(await _flatSky(110, 150, 210));
    const w = 270, h = 600;
    r.resize(w, h);
    r
      ..setSun(noonSun(dirFrom(90, 30)))
      ..setClouds(const SkyClouds(coverage: 0.9, shadow: 0, windVelocity: (10, 0)));
    r.setCloudPlates(CloudPlates(await rampPlate(), await rampPlate()));
    // Several drift positions, so wrap lines cross the checked area.
    var worst = 0.0;
    for (final t in [0.0, 150.0, 300.0, 450.0]) {
      final b = await _frame(r, time: t);
      for (var y = (h * 0.4).round(); y < h - 1; y++) {
        for (var x = 0; x < w - 1; x++) {
          final l = _luma(b, w, x, y);
          worst = math.max(worst, math.max((l - _luma(b, w, x + 1, y)).abs(), (l - _luma(b, w, x, y + 1)).abs()));
        }
      }
    }
    printOnFailure('largest step between neighbouring pixels $worst');
    expect(worst, lessThan(8)); // a repeat seam on this ramp is a step of ~100
  }, skip: skip);

  test('the approved plates draw clouds that drift downwind', () async {
    Future<ui.Image> load(String name) async {
      final codec = await ui.instantiateImageCodec(File('../assets/clouds/$name').readAsBytesSync());
      return (await codec.getNextFrame()).image;
    }

    final sun = dirFrom(35, 40);
    final r = await _make(await daySky(sun, w: 512, h: 256));
    const w = 270, h = 600;
    r.resize(w, h);
    r.setSun(noonSun(sun));
    final clear = await _frame(r);
    r.setClouds(const SkyClouds(coverage: 0.45, windVelocity: (10, 0), shadow: 0));
    expect(r.setCloudPlates(CloudPlates(await load('cumulus_02.png'), await load('cumulus_06.png'))),
        CloudSource.plates);
    final a = await _frame(r, time: 0);
    final b = await _frame(r, time: 10);
    var cloudPx = 0, moved = 0;
    for (var i = 0; i < a.length; i += 4) {
      final d = (a[i] - clear[i]).abs() + (a[i + 1] - clear[i + 1]).abs() + (a[i + 2] - clear[i + 2]).abs();
      if (d > 3) cloudPx++;
      final m = (a[i] - b[i]).abs() + (a[i + 1] - b[i + 1]).abs() + (a[i + 2] - b[i + 2]).abs();
      if (m > 3) moved++;
    }
    printOnFailure('plate cloud px $cloudPx moved $moved of ${w * h}');
    expect(cloudPx, greaterThan(w * h * 0.1));
    expect(cloudPx, lessThan(w * h * 0.98)); // some clear sky remains
    expect(moved, greaterThan(w * h * 0.03));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  final pngPath = Platform.environment['ILLUNIS_DAY_PNG'];
  test('writes a full-size day frame', () async {
    // 13:00-style: sun ~25 degrees up, a little to the right of straight ahead.
    final sunAz = double.tryParse(Platform.environment['ILLUNIS_DAY_AZ'] ?? '') ?? 20;
    final sunEl = double.tryParse(Platform.environment['ILLUNIS_DAY_EL'] ?? '') ?? 25;
    final tier = int.tryParse(Platform.environment['ILLUNIS_DAY_TIER'] ?? '') ?? 0;
    // ILLUNIS_DAY_SUN=x,y,z,r,g,b,intensity,dayFade: the app's own daySun
    // values (lib/app/day_sky.dart) for a real time and place.
    final real = (Platform.environment['ILLUNIS_DAY_SUN'] ?? '').split(',').map(double.tryParse).toList();
    final skySun = real.length == 8 && real.every((v) => v != null)
        ? SkySun(dir: (real[0]!, real[1]!, real[2]!), angularRadius: 0.00465,
            colour: (real[3]!, real[4]!, real[5]!), intensity: real[6]!, dayFade: real[7]!)
        : SkySun(dir: dirFrom(sunAz, sunEl), angularRadius: 0.00465, colour: (1.0, 0.93, 0.82),
            intensity: 0.9, dayFade: 1);
    final sun = skySun.dir;
    final r = await _make(await daySky(sun));
    const w = 1080, h = 2400;
    r.resize(w, h);
    r
      ..setSun(skySun)
      // ILLUNIS_DAY_CLOUDS=0: no clouds (to look at the bare disc).
      ..setClouds(Platform.environment['ILLUNIS_DAY_CLOUDS'] == '0'
          ? null
          : SkyClouds(coverage: 0.45, windVelocity: (4, 1), tier: tier));
    // ILLUNIS_DAY_PLATES=1: the approved plates from ../assets/clouds.
    if (Platform.environment['ILLUNIS_DAY_PLATES'] == '1') {
      Future<ui.Image> load(String name) async {
        final codec = await ui.instantiateImageCodec(File('../assets/clouds/$name').readAsBytesSync());
        return (await codec.getNextFrame()).image;
      }

      r.setCloudPlates(CloudPlates(await load('cumulus_02.png'), await load('cumulus_06.png')));
    }
    ui.Image? img;
    // A few seconds of the near-calm default with ambient drops.
    for (var i = 0; i < 6;) {
      final next = r.frame(1 / 30, time: 3 + i / 30, stillness: 0.04);
      if (next == null) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        continue;
      }
      img = next;
      i++;
    }
    final png = await img!.toByteData(format: ui.ImageByteFormat.png);
    File(pngPath!).writeAsBytesSync(png!.buffer.asUint8List());
  }, skip: skip || pngPath == null, timeout: const Timeout(Duration(minutes: 5)));
}
