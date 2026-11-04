// The tokens (docs/UI_PLAN.md section 3, owner amendments A1 and A3): every
// text pair reads at 4.5:1 or more on the glass, at the plan's typical and
// worst glass and over any sky once the tint is solved for it; rules reach
// 3:1; the type scale has five steps with the floors; no pill radius.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';

Color over(Palette p, double a, Color sky) => composite(p.glass, a, sky);

/// Skies from black to white through the colours the app draws: night
/// blues, a moonlit grey, dusk, the day zenith, haze.
const skies = [
  Color(0xFF000000), Color(0xFF0B1630), Color(0xFF1C2E5C), Color(0xFF223A5E), Color(0xFF4A4F7E),
  Color(0xFF6C7AA0), Color(0xFF3B78C9), Color(0xFF8FB3D9), Color(0xFFBFE0F5), Color(0xFFC8C8C4),
  Color(0xFFE8A060), Color(0xFF808080), Color(0xFFFFFFFF),
];

void main() {
  final typical = {Palette.night: (0.40, const Color(0xFF1C2E5C)), Palette.day: (0.45, const Color(0xFFBFE0F5))};
  final worst = {Palette.night: (0.80, const Color(0xFFFFFFFF)), Palette.day: (0.80, const Color(0xFF000000))};

  for (final (name, cases) in [('typical', typical), ('worst', worst)]) {
    test('every text pair is 4.5:1 and the rule 3:1 on $name glass', () {
      for (final MapEntry(key: p, value: (a, sky)) in cases.entries) {
        final glass = over(p, a, sky);
        for (final t in p.texts) {
          expect(contrast(t, glass), greaterThanOrEqualTo(4.5), reason: '$t on $glass');
        }
        expect(contrast(p.rule, glass), greaterThanOrEqualTo(3), reason: 'rule on $glass');
        // Selected text: the ink still reads on the selection colour.
        expect(contrast(p.ink, Color.alphaBlend(p.selection, glass)), greaterThanOrEqualTo(4.5));
      }
    });
  }

  test('the solved tint keeps every text at 4.5:1 over any sky, and stays clear over a dark night', () {
    for (final p in [Palette.night, Palette.day]) {
      for (final sky in skies) {
        final a = solveGlassAlpha(p, [sky]);
        for (final t in p.texts) {
          expect(contrast(t, over(p, a, sky)), greaterThanOrEqualTo(4.5), reason: '$t over $sky at $a');
        }
      }
    }
    // A1: the night glass is nearly clear over the night sky, the day
    // glass over the day haze.
    expect(solveGlassAlpha(Palette.night, [const Color(0xFF0B1630)]), GlassSpec.alphaFloor);
    expect(solveGlassAlpha(Palette.day, [const Color(0xFFE8EEF5)]), GlassSpec.alphaFloor);
    expect(solveGlassAlpha(Palette.night, [const Color(0xFFFFFFFF)]), greaterThan(0.6));
  });

  test('palettes lerp from night to day', () {
    expect(Palette.lerp(Palette.night, Palette.day, 0), Palette.night);
    expect(Palette.lerp(Palette.night, Palette.day, 1), Palette.day);
    final mid = Palette.lerp(Palette.night, Palette.day, 0.5);
    expect(mid.ink, isNot(Palette.night.ink));
    expect(mid.ink, isNot(Palette.day.ink));
  });

  test('five type steps: families, sizes, floors, tracking 0 on body', () {
    const c = Color(0xFF000000);
    expect(TypeScale.display(c).fontFamily, Fonts.serif);
    expect(TypeScale.display(c).fontSize, 28);
    expect(TypeScale.reply(c).fontFamily, Fonts.serif);
    expect(TypeScale.reply(c).fontSize, 22);
    expect([for (final s in TypeScale.replySteps) s.$1], [22, 20, 18]);
    expect(TypeScale.replySteps.last.$1, TypeScale.replyFloor);
    expect(TypeScale.reply(c, size: 18).height! * 18, closeTo(25, 0.01));
    expect(TypeScale.body(c).fontFamily, Fonts.sans);
    expect(TypeScale.body(c).fontSize, 16);
    expect(TypeScale.body(c).letterSpacing, 0);
    expect(TypeScale.label(c).fontSize, 14);
    expect(TypeScale.note(c).fontSize, TypeScale.floor);
    expect(TypeScale.label(c).fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(TypeScale.body(c, tabular: true).fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('no pills: both radii are under 0.4 x a 48 px target', () {
    for (final r in [Radii.glass, Radii.control]) {
      expect(r, lessThan(Radii.maxFor(Space.target)));
    }
  });

  group('SkyProbe', () {
    ByteData grid(int w, int h, Color Function(int x, int y) at) {
      final b = ByteData(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final c = at(x, y);
          final i = (y * w + x) * 4;
          b.setUint8(i, (c.r * 255).round());
          b.setUint8(i + 1, (c.g * 255).round());
          b.setUint8(i + 2, (c.b * 255).round());
          b.setUint8(i + 3, 255);
        }
      }
      return b;
    }

    const night = Color(0xFF0B1630);

    test('a dark sky gives a dark range and the clearest glass', () {
      final probe = SkyProbe.fromRgba(grid(45, 100, (_, _) => night), 45, 100);
      final (lo, hi) = probe.range(const Rect.fromLTWH(16, 300, 328, 200))!;
      expect(contrast(lo, night), lessThan(1.05));
      expect(contrast(hi, night), lessThan(1.05));
      final sky = SkyLight(daylight: 0, palette: Palette.night, probe: probe, child: const SizedBox());
      expect(sky.glassAlpha(const Rect.fromLTWH(16, 300, 328, 200)), GlassSpec.alphaFloor);
    });

    test('a moon disc behind a panel thickens only that panel', () {
      const moon = Rect.fromLTWH(160, 380, 40, 40);
      final probe = SkyProbe.fromRgba(grid(45, 100, (_, _) => night), 45, 100, discs: [moon]);
      final sky = SkyLight(daylight: 0, palette: Palette.night, probe: probe, child: const SizedBox());
      final behind = sky.glassAlpha(const Rect.fromLTWH(16, 340, 328, 120));
      final away = sky.glassAlpha(const Rect.fromLTWH(16, 680, 328, 64));
      expect(behind, greaterThan(away));
      expect(away, GlassSpec.alphaFloor);
      // And the text still reads over the brightest point behind it.
      final (_, hi) = probe.range(const Rect.fromLTWH(16, 340, 328, 120))!;
      for (final t in Palette.night.texts) {
        expect(contrast(t, over(Palette.night, behind, hi)), greaterThanOrEqualTo(4.5));
      }
    });

    test('similar looks are not a change', () {
      final a = SkyProbe.fromRgba(grid(8, 8, (_, _) => night), 8, 8);
      final b = SkyProbe.fromRgba(grid(8, 8, (_, _) => night), 8, 8);
      final c = SkyProbe.fromRgba(grid(8, 8, (x, _) => x < 4 ? night : const Color(0xFFFFFFFF)), 8, 8);
      expect(a.similarTo(b), isTrue);
      expect(a.similarTo(c), isFalse);
      expect(a.similarTo(null), isFalse);
    });
  });

  test('without a probe the plan model: discs, twilight, night, day', () {
    SkyLight sky(double d, [List<Rect> discs = const []]) =>
        SkyLight(daylight: d, palette: Palette.night, discs: discs, child: const SizedBox());
    const panel = Rect.fromLTWH(16, 300, 328, 200);
    expect(sky(0).glassAlpha(panel), GlassSpec.modelNight);
    expect(sky(1).glassAlpha(panel), GlassSpec.modelDay);
    expect(sky(0.5).glassAlpha(panel), GlassSpec.modelTwilight);
    expect(sky(0, [const Rect.fromLTWH(150, 280, 30, 30)]).glassAlpha(panel), GlassSpec.unknown);
  });
}
