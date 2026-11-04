// Test fixtures for the day sky: an equirect day bake like the app's (a CPU
// port of client/shaders/sky.frag's atmosphere and tone curve, without the
// sun disc, as the per-pixel path bakes it), and helpers shared by the GPU
// day tests.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:illunis_gpu/illunis_gpu.dart';

bool gpuAvailable() {
  try {
    gpu.gpuContext;
    return true;
  } catch (_) {
    return false;
  }
}

typedef V3 = (double, double, double);

V3 dirFrom(double azDeg, double elDeg) {
  final a = azDeg * math.pi / 180, e = elDeg * math.pi / 180;
  return (math.cos(e) * math.sin(a), math.sin(e), math.cos(e) * math.cos(a));
}

Future<ui.Image> imageFromRgba(Uint8List px, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

Future<Uint8List> rgba(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

const _rayleigh = (5.804542996261093e-6, 1.3562911419845635e-5, 3.0265902468824876e-5);
const _mieConst = (1.8399918514433978e14, 2.7798023919660528e14, 4.0790479543861094e14);

double _sunIntensity(double zc) =>
    1000 * math.max(0.0, 1 - math.exp(-((1.6110731556870734 - math.acos(zc.clamp(-1.0, 1.0))) / 1.5)));

double _smooth(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _aces(double x) => ((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)).clamp(0.0, 1.0);

/// Display-coded day sky (equirect, water frame: u = 0.5 + atan(x, z) / 2pi,
/// v = 0.5 - elevation / pi) for a sun at [sun].
Future<ui.Image> daySky(V3 sun,
    {int w = 1024, int h = 512, double turbidity = 2.4, double mie = 1.2, double exposure = 0.26}) {
  final (sx, sy, sz) = sun;
  final altDeg = math.asin(sy) * 180 / math.pi;
  final fy = math.max(sy, -0.012);
  final fl = math.sqrt(sx * sx + fy * fy + sz * sz);
  final lx = sx / fl, ly = fy / fl, lz = sz / fl;
  final twilight = _smooth(-18, -0.7, altDeg);
  final sunfade = 1 - (1 - math.exp(sy * 0.89)).clamp(0.0, 1.0);
  final rc = 3.1 - (1 - sunfade);
  final bR = [_rayleigh.$1 * rc, _rayleigh.$2 * rc, _rayleigh.$3 * rc];
  final mc = 0.434 * (0.2 * turbidity) * 10.0e-18 * 0.0014 * mie;
  final bM = [_mieConst.$1 * mc, _mieConst.$2 * mc, _mieConst.$3 * mc];
  final e = _sunIntensity(ly) * math.pow(twilight, 1.5);
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final el = (0.5 - (y + 0.5) / h) * math.pi;
    for (var x = 0; x < w; x++) {
      final az = ((x + 0.5) / w - 0.5) * 2 * math.pi;
      var dy = math.sin(el);
      if (dy < 0.0035) dy = 0.0035; // the bake's ground sees the horizon air
      final ch = math.sqrt(1 - dy * dy);
      final dx = ch * math.sin(az), dz = ch * math.cos(az);
      final zen = math.acos(math.max(0.0, dy));
      final inv = 1 / (math.max(0.0, dy) + 0.15 * math.pow(93.885 - zen * 180 / math.pi, -1.253));
      final cosT = dx * lx + dy * ly + dz * lz;
      final rPhase = 0.05968310365946075 * (1 + cosT * cosT);
      const g = 0.8, g2 = g * g;
      final pb = 1 - 2 * g * cosT + g2;
      final mPhase = 0.07957747154594767 * ((1 - g2) / (pb * math.sqrt(pb)));
      final horizon = 1 - ly, h2 = horizon * horizon;
      final hk = (h2 * h2 * horizon).clamp(0.0, 1.0);
      final i = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        final fex = math.exp(-(bR[c] * 8.4e3 * inv + bM[c] * 1.25e3 * inv));
        final bt = bR[c] * rPhase + bM[c] * mPhase;
        final lt = e * (bt / (bR[c] + bM[c]));
        final rad = math.max(lt * (1 - fex), 0.0);
        var lin = rad * math.sqrt(rad);
        lin *= 1 + (math.sqrt(math.max(lt * fex, 0.0)) - 1) * hk;
        final adapted = math.pow(math.max(lin * 0.04, 0.0), 1 / (1.2 + 1.2 * sunfade)).toDouble();
        final resp = adapted + (lin * 0.012 - adapted) * _smooth(0, 18, altDeg);
        final col = math.pow(_aces(resp * exposure), 1 / 2.2);
        px[i + c] = (col * 255).round().clamp(0, 255);
      }
      px[i + 3] = 255;
    }
  }
  return imageFromRgba(px, w, h);
}

/// A white-ish noon sun at [dir].
SkySun noonSun(V3 dir, {double dayFade = 1}) => SkySun(
    dir: dir, angularRadius: 0.00465, colour: (1.0, 0.97, 0.92), intensity: 0.95, dayFade: dayFade);
