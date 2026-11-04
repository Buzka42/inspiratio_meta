// Render tests for the Reflection water: one full-screen water surface that
// reflects an equirectangular sky. Everything is compared in memory; no
// golden files are written. The sky is a small generated image (synthetic,
// no user data).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart' show SkySun;
import 'package:illunis_client/widgets/water_pass.dart';

// Portrait render, phone-like aspect (logical = physical in the tester).
const _w = 144, _h = 256;
const _sw = 256, _sh = 128; // equirectangular test sky, 2:1

/// Smooth colour field over the sky sphere: red varies with azimuth, green
/// and blue with elevation, so any normal tilt changes the sampled colour.
Uint8List _skyPixels() {
  final px = Uint8List(_sw * _sh * 4);
  for (var y = 0; y < _sh; y++) {
    for (var x = 0; x < _sw; x++) {
      final u = (x + 0.5) / _sw, v = (y + 0.5) / _sh;
      final i = (y * _sw + x) * 4;
      px[i] = (128 + 100 * math.sin(2 * math.pi * u * 2)).round();
      px[i + 1] = (30 + 300 * v).round().clamp(0, 255);
      px[i + 2] = (128 + 100 * math.cos(2 * math.pi * v * 1.5)).round();
      px[i + 3] = 255;
    }
  }
  return px;
}

// Calm-water constants mirrored from shaders/water.frag.
const _camH = 1.0, _pitch = 0.785398, _fovS = 1.2;
const _tint = [0.92, 0.97, 1.0], _waterCol = [0.02, 0.05, 0.08];
const _f0 = 0.02, _reflK = 0.62, _hazeK = 0.09;

double _schlick(double c) => _f0 + (1 - _f0) * math.pow(1 - c, 5);

/// Bilinear sample with clamped edges, texel centres at (i + 0.5) / size.
double _bilinear(Uint8List sky, double u, double v, int c) {
  final fx = u * _sw - 0.5, fy = v * _sh - 0.5;
  final x0 = fx.floor(), y0 = fy.floor();
  final tx = fx - x0, ty = fy - y0;
  double at(int x, int y) =>
      sky[(y.clamp(0, _sh - 1) * _sw + x.clamp(0, _sw - 1)) * 4 + c].toDouble();
  final top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx;
  final bot = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx;
  return top * (1 - ty) + bot * ty;
}

/// The mirror-flat reflection of [sky]: what water.frag paints with no
/// ripples (vignette off, no sun). [legacy] uses the pre-Schlick shader
/// (0.62 Fresnel floor, no haze) for the look comparison.
Uint8List _flatReflection(Uint8List sky, {bool legacy = false, bool haze = true}) {
  final out = Uint8List(_w * _h * 4);
  final sp = math.sin(_pitch), cp = math.cos(_pitch);
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      final sx = ((x + 0.5) / _w - 0.5) * (_w / _h) * _fovS;
      final sy = ((y + 0.5) / _h - 0.5) * _fovS;
      var dx = sx, dy = -sp - cp * sy, dz = cp - sp * sy;
      final len = math.sqrt(dx * dx + dy * dy + dz * dz);
      dx /= len; dy /= len; dz /= len;
      assert(_camH > 0);
      // Flat normal (0,1,0): the reflection flips y.
      final ry = math.max(-dy, 0.01);
      final rl = math.sqrt(dx * dx + ry * ry + dz * dz);
      final u = 0.5 + math.atan2(dx / rl, dz / rl) / (2 * math.pi);
      final v = 0.5 - math.asin(ry / rl) / math.pi;
      final cosT = (-dy).clamp(0.0, 1.0);
      final refl = legacy
          ? 0.62 + 0.38 * math.pow(1 - cosT, 3)
          : 1 - math.exp(-_reflK / _schlick(sp) * _schlick(cosT));
      final t = _camH / math.max(-dy, 1e-3);
      final mist = legacy || !haze ? 0.0 : 1 - math.exp(-_hazeK * math.max(t - _camH, 0));
      final hu = 0.5 + math.atan2(dx, dz) / (2 * math.pi);
      final o = (y * _w + x) * 4;
      for (var c = 0; c < 3; c++) {
        final s = _bilinear(sky, u, v, c) / 255 * _tint[c];
        final col = _waterCol[c] + (s - _waterCol[c]) * refl;
        final h = _bilinear(sky, hu, 0.49, c) / 255;
        out[o + c] = ((col + (h - col) * mist) * 255).round().clamp(0, 255);
      }
      out[o + 3] = 255;
    }
  }
  return out;
}

class _Diff {
  _Diff(this.mean, this.max);
  final double mean;
  final int max;
  @override
  String toString() => 'mean=${mean.toStringAsFixed(2)} max=$max';
}

/// Channel difference over the pixel window [x0,x1) x [y0,y1).
_Diff _diff(Uint8List a, Uint8List b, {int x0 = 0, int y0 = 0, int x1 = _w, int y1 = _h}) {
  var sum = 0, mx = 0, n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      for (var c = 0; c < 3; c++) {
        final i = (y * _w + x) * 4 + c;
        final d = (a[i] - b[i]).abs();
        sum += d;
        if (d > mx) mx = d;
        n++;
      }
    }
  }
  return _Diff(sum / n, mx);
}

Future<Uint8List> _render(
  WidgetTester t, {
  required ui.FragmentProgram program,
  required ui.Image sky,
  required Offset walker,
  required double loudness,
  double vignette = 0,
  double stillness = 1,
  SkySun? sun,
  RippleSources? ripples,
}) async {
  final key = GlobalKey();
  await t.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(
          width: _w.toDouble(),
          height: _h.toDouble(),
          child: WaterPass(
            sky: sky,
            walker: walker,
            loudness: loudness,
            vignette: vignette,
            stillness: stillness,
            sun: sun,
            ripples: ripples,
            programLoader: () async => program,
          ),
        ),
      ),
    ),
  ));
  await t.pump(); // loader future resolves, shader branch builds
  expect(find.byKey(const ValueKey('water-shader')), findsOneWidget);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await t.runAsync(() async {
    final img = await boundary.toImage();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

// Off-screen walker: its view ray points above the water, so no rings.
const _offScreen = Offset(0.5, -4);
const _near = Offset(0.5, 0.7);

// Tolerances in 8-bit channel levels, calibrated on the flutter_tester
// renderer with this 144x256 render and 256x128 sky. Measured 2026-10-24:
// calm vs flat reflection mean 2.82 / max 15 (bands up to 3.02), against a
// full-screen colour spread of 93.6; near the walker, quiet 3.79, loud 12.70,
// loud vs quiet 9.93 there and 2.85 in the far top band. The residual calm
// difference is the always-on swell and capillary ripples.
// Per-band allowance is wider: the bottom band reflects sky near the zenith,
// where the test sky's azimuth term changes fastest (measured 4.94).
const _calmMean = 4.5, _calmMax = 24, _calmBandMean = 7.0;
const _loudWindowMean = 8.0;

/// Mean of r+g+b over [p] in the window [x0,x1) x [y0,y1).
double _meanLum(Uint8List p, {int x0 = 0, int y0 = 0, int x1 = _w, int y1 = _h}) {
  var s = 0, n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * _w + x) * 4;
      s += p[i] + p[i + 1] + p[i + 2];
      n++;
    }
  }
  return s / n;
}

/// A white sun ahead of the camera, 30 degrees up (water frame). Flat water
/// mirrors it at screen centre-x, row ~0.21 of the height.
SkySun _sun({double up = 30}) {
  final e = up * math.pi / 180;
  return SkySun(
      dir: (0.0, math.sin(e), math.cos(e)),
      angularRadius: 0.00465,
      colour: (1.0, 0.95, 0.85),
      intensity: 1,
      dayFade: 1);
}

void main() {
  late ui.FragmentProgram program;
  late ui.Image sky;
  late Uint8List skyPx, flat;

  setUpAll(() {
    skyPx = _skyPixels();
    flat = _flatReflection(skyPx);
  });

  Future<void> load(WidgetTester t) async {
    await t.runAsync(() async {
      program = await ui.FragmentProgram.fromAsset('shaders/water.frag');
      final buf = await ui.ImmutableBuffer.fromUint8List(skyPx);
      final desc = ui.ImageDescriptor.raw(buf,
          width: _sw, height: _sh, pixelFormat: ui.PixelFormat.rgba8888);
      final codec = await desc.instantiateCodec();
      sky = (await codec.getNextFrame()).image;
    });
  }

  testWidgets('the full screen renders as reflected sky, not a flat fill', (t) async {
    await load(t);
    final out = await _render(t, program: program, sky: sky, walker: _offScreen, loudness: 0);
    // Every pixel is water: opaque, and the picture varies across the whole
    // screen (top rows reflect low sky, bottom rows high sky).
    for (var i = 3; i < out.length; i += 4) {
      expect(out[i], 255);
    }
    // Per-channel standard deviation over the whole screen.
    var spread = 0.0;
    for (var c = 0; c < 3; c++) {
      var s = 0.0, s2 = 0.0;
      for (var i = c; i < out.length; i += 4) {
        s += out[i];
        s2 += out[i] * out[i];
      }
      final n = out.length / 4;
      spread += math.sqrt(math.max(s2 / n - (s / n) * (s / n), 0));
    }
    debugPrint('full-screen colour spread (sum of channel std devs): ${spread.toStringAsFixed(1)}');
    expect(spread, greaterThan(20), reason: 'no flat fill');
    // And it is the reflection everywhere: top, middle and bottom bands all
    // track the flat reflection (no sky band, no horizon split).
    for (final band in [(0, _h ~/ 8), (_h * 7 ~/ 16, _h * 9 ~/ 16), (_h * 7 ~/ 8, _h)]) {
      final d = _diff(out, flat, y0: band.$1, y1: band.$2);
      debugPrint('rows ${band.$1}-${band.$2} vs flat: $d');
      expect(d.mean, lessThan(_calmBandMean), reason: 'rows ${band.$1}-${band.$2}: $d');
    }
  });

  testWidgets('a voice ripple rings the centre of calm water, then fades away', (t) async {
    await load(t);
    var now = 0.0;
    final rip = RippleSources(clock: () => now);
    Future<Uint8List> at(double s) {
      now = s;
      return _render(t,
          program: program, sky: sky, walker: _offScreen, loudness: 0, stillness: 0, ripples: rip);
    }

    final still = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, stillness: 0);
    rip.start(0.6);
    final ring = await at(0.6);
    final gone = await at(RippleSources.life + 0.1);
    // Centre window: the ring's radius at 0.6 s is about 0.2 surface units.
    const box = (x0: _w ~/ 4, y0: _h * 3 ~/ 8, x1: _w * 3 ~/ 4, y1: _h * 5 ~/ 8);
    final dRing = _diff(ring, still, x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1);
    final dGone = _diff(gone, still);
    debugPrint('voice ripple at 0.6 s, centre: $dRing; after its life, screen: $dGone');
    expect(dRing.mean, greaterThan(2.0), reason: 'ring visible at the centre');
    expect(dGone.max, 0, reason: 'nothing left once the ripple has faded');
  });

  testWidgets('silence with the walker off-screen is close to the sky reflection', (t) async {
    await load(t);
    final out = await _render(t, program: program, sky: sky, walker: _offScreen, loudness: 0);
    final d = _diff(out, flat);
    debugPrint('loud 0, walker off-screen vs flat reflection: $d');
    // Only the faint swell and capillary ripples remain.
    expect(d.mean, lessThan(_calmMean));
    expect(d.max, lessThanOrEqualTo(_calmMax));
  });

  testWidgets('a loud voice disturbs the water near the walker', (t) async {
    await load(t);
    final quiet = await _render(t, program: program, sky: sky, walker: _near, loudness: 0);
    final loud = await _render(t, program: program, sky: sky, walker: _near, loudness: 1);
    // Window around the walker (x 0.5, y 0.7 of the screen), and a band at
    // the top of the screen far from it.
    const win = (x0: _w * 3 ~/ 10, y0: _h * 6 ~/ 10, x1: _w * 7 ~/ 10, y1: _h * 8 ~/ 10);
    final dq = _diff(quiet, flat, x0: win.x0, y0: win.y0, x1: win.x1, y1: win.y1);
    final dl = _diff(loud, flat, x0: win.x0, y0: win.y0, x1: win.x1, y1: win.y1);
    final dql = _diff(loud, quiet, x0: win.x0, y0: win.y0, x1: win.x1, y1: win.y1);
    final far = _diff(loud, quiet, y1: _h ~/ 8);
    debugPrint('near walker vs flat: quiet $dq, loud $dl; loud vs quiet $dql; far $far');
    expect(dl.mean, greaterThan(_loudWindowMean), reason: 'rings should be clearly visible');
    expect(dl.mean, greaterThan(dq.mean * 2));
    expect(dql.mean, greaterThan(_loudWindowMean / 2));
    expect(dql.mean, greaterThan(far.mean * 2), reason: 'the change centres on the walker');
  });

  testWidgets('Schlick Fresnel keeps the screen look close to the old floor', (t) async {
    await load(t);
    final out = await _render(t, program: program, sky: sky, walker: _offScreen, loudness: 0);
    final legacy = _flatReflection(skyPx, legacy: true);
    final now = _meanLum(out), old = _meanLum(legacy);
    // Physical F0 = 0.02 brightens the grazing top and dims the near bottom.
    final top = _meanLum(out, y1: _h ~/ 8), oldTop = _meanLum(legacy, y1: _h ~/ 8);
    final bot = _meanLum(out, y0: _h * 7 ~/ 8), oldBot = _meanLum(legacy, y0: _h * 7 ~/ 8);
    debugPrint('mean lum: shader ${now.toStringAsFixed(1)} vs old ${old.toStringAsFixed(1)}; '
        'top ${top.toStringAsFixed(1)}/${oldTop.toStringAsFixed(1)}, '
        'bottom ${bot.toStringAsFixed(1)}/${oldBot.toStringAsFixed(1)}');
    expect((now / old - 1).abs(), lessThan(0.06), reason: 'screen brightness comparable');
  });

  testWidgets('the sun glints where calm water mirrors it, and spreads with roughness',
      (t) async {
    await load(t);
    final none = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, stillness: 0.04);
    final calm = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, stillness: 0.04, sun: _sun());
    final rough = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, stillness: 1, sun: _sun());
    final roughNone = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, stillness: 1);
    // Mirror point of a 30 degree sun: view ray 30 degrees down, 15 above the
    // camera's forward axis, so sy = -tan(15deg) / FOV_S.
    final cy = ((0.5 - math.tan(15 * math.pi / 180) / _fovS) * _h).round();
    const cx = _w ~/ 2;
    int lum(Uint8List p, int x, int y) {
      final i = (y * _w + x) * 4;
      return p[i] + p[i + 1] + p[i + 2];
    }
    final spot = (x0: cx - 4, y0: cy - 4, x1: cx + 4, y1: cy + 4);
    final calmGain = _meanLum(calm, x0: spot.x0, y0: spot.y0, x1: spot.x1, y1: spot.y1) -
        _meanLum(none, x0: spot.x0, y0: spot.y0, x1: spot.x1, y1: spot.y1);
    // Glint area: pixels the sun brightens by more than 30 levels (r+g+b).
    int area(Uint8List a, Uint8List b) {
      var n = 0;
      for (var y = 0; y < _h; y++) {
        for (var x = 0; x < _w; x++) {
          if (lum(a, x, y) - lum(b, x, y) > 30) n++;
        }
      }
      return n;
    }
    final calmArea = area(calm, none), roughArea = area(rough, roughNone);
    final roughGain = _meanLum(rough, x0: spot.x0, y0: spot.y0, x1: spot.x1, y1: spot.y1) -
        _meanLum(roughNone, x0: spot.x0, y0: spot.y0, x1: spot.x1, y1: spot.y1);
    // Brightening of the bottom quarter, well outside a 30 degree sun's lobe.
    final washRough = _meanLum(rough, y0: _h * 3 ~/ 4) - _meanLum(roughNone, y0: _h * 3 ~/ 4);
    debugPrint('glint: spot gain calm ${calmGain.toStringAsFixed(1)}, '
        'rough ${roughGain.toStringAsFixed(1)}; area calm $calmArea, rough $roughArea '
        'of ${_w * _h}; bottom-quarter gain rough ${washRough.toStringAsFixed(1)}');
    expect(calmGain, greaterThan(200), reason: 'a bright glint at the mirror point');
    expect(roughArea, greaterThan(calmArea * 3), reason: 'rough water spreads the glint');
    expect(roughGain, lessThan(calmGain), reason: 'the spread lobe is dimmer at its peak');
    expect(washRough, lessThan(15), reason: 'no full-screen wash');
    // The bottom corners, far from the lobe, are untouched.
    expect((lum(calm, 2, _h - 3) - lum(none, 2, _h - 3)).abs(), lessThanOrEqualTo(3));
  });

  testWidgets('no glint at night or with the sun below the horizon', (t) async {
    expect(glintUniforms(null).$2, [0.0, 0.0, 0.0]);
    expect(glintUniforms(_sun(up: -2)).$2, [0.0, 0.0, 0.0]);
    final (dir, light) = glintUniforms(_sun());
    expect(dir[1], closeTo(0.5, 1e-9));
    expect(light, [1.0, 0.95, 0.85]);
    await load(t);
    final none = await _render(t, program: program, sky: sky, walker: _offScreen, loudness: 0);
    final below = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, sun: _sun(up: -2));
    expect(_diff(none, below).max, 0);
  });

  testWidgets('far water fades toward the horizon colour', (t) async {
    await load(t);
    final out = await _render(t, program: program, sky: sky, walker: _offScreen, loudness: 0);
    final clear = _flatReflection(skyPx, haze: false);
    // The top band (longest path) tracks the hazed model, not the clear one;
    // the bottom band (path about CAM_H) is nearly unchanged by haze.
    final top = (y1: _h ~/ 16);
    final dHaze = _diff(out, flat, y1: top.y1), dClear = _diff(out, clear, y1: top.y1);
    final hazeShift = _diff(flat, clear, y1: top.y1);
    final botShift = _diff(flat, clear, y0: _h * 15 ~/ 16);
    debugPrint('top band: vs hazed $dHaze, vs clear $dClear; haze shift top $hazeShift, '
        'bottom $botShift');
    expect(hazeShift.mean, greaterThan(4), reason: 'haze visible at the top');
    expect(dHaze.mean, lessThan(dClear.mean));
    expect(botShift.mean, lessThan(hazeShift.mean / 3));
  });

  testWidgets('vignette darkens the screen corners, not the centre', (t) async {
    await load(t);
    final off = await _render(t, program: program, sky: sky, walker: _offScreen, loudness: 0);
    final on = await _render(t,
        program: program, sky: sky, walker: _offScreen, loudness: 0, vignette: 1);
    int lum(Uint8List p, int x, int y) {
      final i = (y * _w + x) * 4;
      return p[i] + p[i + 1] + p[i + 2];
    }
    expect(lum(on, _w - 1, _h - 1), lessThan(lum(off, _w - 1, _h - 1) * 0.85));
    expect((lum(on, _w ~/ 2, _h ~/ 2) - lum(off, _w ~/ 2, _h ~/ 2)).abs(), lessThanOrEqualTo(3));
  });

  testWidgets('falls back to the plain image when the shader fails', (t) async {
    await load(t);
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: WaterPass(sky: sky, programLoader: () => Future.error(StateError('no shader'))),
    ));
    await t.pump();
    expect(find.byKey(const ValueKey('water-fallback')), findsOneWidget);
    expect(find.byKey(const ValueKey('water-shader')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('procedural sky is a 2:1 equirectangular image with stars', (t) async {
    final px = await t.runAsync(() async {
      final img = await proceduralEquirectSky(width: 1024);
      expect(img.width, 1024);
      expect(img.height, 512);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return data!.buffer.asUint8List();
    });
    // Upper hemisphere: count pixels much brighter than the gradient there.
    var bright = 0;
    for (var y = 20; y < 200; y++) {
      for (var x = 0; x < 1024; x++) {
        final i = (y * 1024 + x) * 4;
        if (px![i] + px[i + 1] + px[i + 2] > 300) bright++;
      }
    }
    debugPrint('procedural sky bright pixels in the dome: $bright');
    expect(bright, greaterThan(50), reason: 'stars or moon should be present');
  });
}
