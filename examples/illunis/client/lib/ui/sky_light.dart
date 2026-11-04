/// What the sky behind the UI looks like right now, for the glass and the
/// ink (owner amendments A1 and A3): how far into the day the sky is, the
/// palette in use, the bright discs (the moon) and a small look at the sky
/// as drawn ([SkyProbe]). Glass asks it for the clearest tint at which every
/// text pair still reaches 4.5:1 over the real sky behind it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'tokens.dart';

class SkyLight extends InheritedWidget {
  const SkyLight({
    super.key,
    required this.daylight,
    required this.palette,
    this.discs = const [],
    this.probe,
    required super.child,
  });

  /// 0 night .. 1 day, from the sun's altitude (`skyInkBlend`).
  final double daylight;

  /// The inks and glass in use: night, day, or on the way between.
  final Palette palette;

  /// Bright discs (the moon) in global coordinates.
  final List<Rect> discs;

  /// The sky as last drawn, blurred like the glass. Null before the first
  /// look and in tests.
  final SkyProbe? probe;

  static SkyLight? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SkyLight>();

  /// The palette in use; night when there is no sky (tests, voice builds).
  static Palette paletteOf(BuildContext context) => maybeOf(context)?.palette ?? Palette.night;

  /// Tint alpha for glass covering [rect] (global). With a [probe], the
  /// lowest alpha at which [palette]'s texts reach the target over the
  /// darkest and brightest sky under [rect]. Without one, the plan's model.
  double glassAlpha(Rect rect) {
    final range = probe?.range(rect);
    if (range == null) return modelAlpha(rect);
    return solveGlassAlpha(palette, [range.$1, range.$2]);
  }

  /// UI_PLAN 3.2: a bright disc behind the glass (inflated by 2 x sigma)
  /// thickens it; twilight is in between; otherwise night or day.
  double modelAlpha(Rect rect) {
    final hit = discs.any((d) => d.inflate(2 * GlassSpec.sigma).overlaps(rect));
    if (hit) return GlassSpec.unknown;
    if (daylight > 0.15 && daylight < 0.85) return GlassSpec.modelTwilight;
    return daylight >= 0.5 ? GlassSpec.modelDay : GlassSpec.modelNight;
  }

  /// The same sky with [palette] in use below it: a text region whose ink
  /// was chosen from the sky behind it ([SkyInk]).
  SkyLight withPalette(Palette palette, Widget child) =>
      SkyLight(daylight: daylight, palette: palette, discs: discs, probe: probe, child: child);

  @override
  bool updateShouldNotify(SkyLight old) =>
      daylight != old.daylight || palette != old.palette || probe != old.probe || !_sameRects(discs, old.discs);

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// WCAG 2.2 contrast of [ink] over a sky of relative luminance [sky].
double contrastOnLuminance(Color ink, double sky) {
  final l = ink.computeLuminance();
  return (math.max(l, sky) + 0.05) / (math.min(l, sky) + 0.05);
}

/// Pale or dark ink for text from the sky actually behind it: the mean
/// relative luminance of [SkyProbe] under the text. The day sky the phone
/// draws runs from deep blue (pale ink reads) to lit cloud (dark ink
/// reads), so the sun's altitude alone cannot choose.
abstract final class SkyInk {
  /// The two inks: [Palette.night]'s and [Palette.day]'s main text.
  static const pale = SkyColors.nightInk, dark = SkyColors.dayInk;

  /// Hysteresis: the other ink must be this many times better to take over,
  /// so a cloud drifting past does not flip the text back and forth.
  static const double switchRatio = 1.5;

  /// True for dark ink on a sky of mean relative luminance [sky]. With no
  /// ink in use yet ([wasDark] null) the higher contrast wins. Otherwise the
  /// ink in use stays unless the other is [switchRatio] times better, or
  /// the one in use is below [GlassSpec.target] where the other reaches it
  /// (the band between, where neither reaches it, is left to the halo).
  static bool isDark(double sky, {bool? wasDark}) {
    final d = contrastOnLuminance(dark, sky), p = contrastOnLuminance(pale, sky);
    if (wasDark == null) return d >= p;
    final (now, other) = wasDark ? (d, p) : (p, d);
    const t = GlassSpec.target;
    final swap = other >= now * switchRatio || (now < t && other >= t);
    return swap ? !wasDark : wasDark;
  }
}

/// Glass tint alpha with no SkyLight above [context]: the worst case.
double glassAlphaAt(BuildContext context, Rect? rect) {
  final sky = SkyLight.maybeOf(context);
  if (sky == null || rect == null) return GlassSpec.unknown;
  return sky.glassAlpha(rect);
}

/// [glass] at [alpha] over [under], per sRGB channel, as the GPU blends it.
Color composite(Color glass, double alpha, Color under) => Color.alphaBlend(glass.withValues(alpha: alpha), under);

/// The lowest alpha from [GlassSpec.alphaFloor] at which every text of
/// [p] reaches [GlassSpec.target] plus its margin over every colour of
/// [skies]; [GlassSpec.alphaMax] when none does.
double solveGlassAlpha(Palette p, List<Color> skies, {double target = GlassSpec.target + GlassSpec.margin}) {
  bool ok(double a) {
    for (final s in skies) {
      final c = composite(p.glass, a, s);
      for (final t in p.texts) {
        if (contrast(t, c) < target) return false;
      }
    }
    return true;
  }

  for (var a = GlassSpec.alphaFloor; a < GlassSpec.alphaMax; a += 0.01) {
    if (ok(a)) return double.parse(a.toStringAsFixed(2));
  }
  return GlassSpec.alphaMax;
}

/// A small picture of the sky as drawn: sRGB colours on a coarse grid,
/// blurred as the glass blurs, with each bright disc painted in white so a
/// moon smaller than a cell still counts.
@immutable
class SkyProbe {
  const SkyProbe._(this.cols, this.rows, this.scale, this._rgb);

  /// Grid cells per logical px ([toImage] pixel ratio).
  static const double defaultScale = 1 / 8;

  final int cols, rows;
  final double scale;
  final Float32List _rgb; // 0..1 sRGB, row-major

  /// From [rgba] (straight 8-bit RGBA, [w] x [h], [scale] cells per
  /// logical px). [discs] are in logical px.
  factory SkyProbe.fromRgba(ByteData rgba, int w, int h,
      {double scale = defaultScale, List<Rect> discs = const [], double sigma = GlassSpec.sigma}) {
    final rgb = Float32List(w * h * 3);
    for (var i = 0; i < w * h; i++) {
      for (var c = 0; c < 3; c++) {
        rgb[i * 3 + c] = rgba.getUint8(i * 4 + c) / 255;
      }
    }
    for (final d in discs) {
      final r = Rect.fromLTRB(d.left * scale, d.top * scale, d.right * scale, d.bottom * scale);
      for (var y = math.max(0, r.top.floor()); y < math.min(h, r.bottom.ceil()); y++) {
        for (var x = math.max(0, r.left.floor()); x < math.min(w, r.right.ceil()); x++) {
          rgb.fillRange((y * w + x) * 3, (y * w + x) * 3 + 3, 1);
        }
      }
    }
    _blur(rgb, w, h, sigma * scale);
    return SkyProbe._(w, h, scale, rgb);
  }

  Color _at(int x, int y) {
    final i = (y * cols + x) * 3;
    return Color.from(alpha: 1, red: _rgb[i], green: _rgb[i + 1], blue: _rgb[i + 2]);
  }

  /// The cells under [rect] (logical px), inclusive, or null off the grid.
  (int, int, int, int)? _cells(Rect rect) {
    final x0 = math.max(0, (rect.left * scale).floor()), x1 = math.min(cols - 1, (rect.right * scale).ceil() - 1);
    final y0 = math.max(0, (rect.top * scale).floor()), y1 = math.min(rows - 1, (rect.bottom * scale).ceil() - 1);
    return x0 > x1 || y0 > y1 ? null : (x0, x1, y0, y1);
  }

  /// The darkest and brightest sky under [rect] (logical px), or null when
  /// [rect] is off the grid.
  (Color, Color)? range(Rect rect) {
    final cells = _cells(rect);
    if (cells == null) return null;
    final (x0, x1, y0, y1) = cells;
    Color? lo, hi;
    double loL = 2, hiL = -1;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final c = _at(x, y);
        final l = c.computeLuminance();
        if (l < loL) (loL, lo) = (l, c);
        if (l > hiL) (hiL, hi) = (l, c);
      }
    }
    return (lo!, hi!);
  }

  /// Mean relative luminance of the sky under [rect] (logical px), or null
  /// when [rect] is off the grid.
  double? meanLuminance(Rect rect) {
    final cells = _cells(rect);
    if (cells == null) return null;
    final (x0, x1, y0, y1) = cells;
    var sum = 0.0;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        sum += _at(x, y).computeLuminance();
      }
    }
    return sum / ((x1 - x0 + 1) * (y1 - y0 + 1));
  }

  /// True when no cell differs from [other] by more than [tolerance] on
  /// any channel (a look not worth a rebuild).
  bool similarTo(SkyProbe? other, {double tolerance = 0.02}) {
    if (other == null || other.cols != cols || other.rows != rows) return false;
    for (var i = 0; i < _rgb.length; i++) {
      if ((_rgb[i] - other._rgb[i]).abs() > tolerance) return false;
    }
    return true;
  }

  /// Separable Gaussian blur in place, [sigma] in cells.
  static void _blur(Float32List rgb, int w, int h, double sigma) {
    if (sigma < 0.3) return;
    final radius = (sigma * 3).ceil();
    final k = [for (var i = -radius; i <= radius; i++) math.exp(-i * i / (2 * sigma * sigma))];
    final sum = k.fold(0.0, (a, b) => a + b);
    for (var i = 0; i < k.length; i++) {
      k[i] /= sum;
    }
    final tmp = Float32List(rgb.length);
    void pass(Float32List src, Float32List dst, bool horizontal) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          for (var c = 0; c < 3; c++) {
            var acc = 0.0;
            for (var j = -radius; j <= radius; j++) {
              final xx = horizontal ? (x + j).clamp(0, w - 1) : x;
              final yy = horizontal ? y : (y + j).clamp(0, h - 1);
              acc += src[(yy * w + xx) * 3 + c] * k[j + radius];
            }
            dst[(y * w + x) * 3 + c] = acc;
          }
        }
      }
    }

    pass(rgb, tmp, true);
    pass(tmp, rgb, false);
  }
}
