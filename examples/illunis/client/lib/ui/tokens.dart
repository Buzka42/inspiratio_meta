/// Design tokens (docs/UI_PLAN.md section 3, with the owner amendments A1 to
/// A3 and the typography decision of 2026-10-29): one palette per sky, night
/// and day, one type scale, the halo that text on the open sky may carry, a
/// 4 px spacing grid, two radii and a few slow motion curves. UI files use
/// only these; no raw colours, font sizes or radii.
library;

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// The named colours behind [Palette.night] and [Palette.day], for the few
/// places that need a compile-time constant (caption presets).
abstract final class SkyColors {
  /// Behind the sky, before it is drawn.
  static const space = Color(0xFF000000);

  static const nightInk = Color(0xFFF5F2EA); // CaptionInk.pale
  static const nightInk2 = Color(0xFFB4BBCB); // moonlit grey
  static const nightAccent = Color(0xFFC5D4FF); // star tint, star_field.dart
  static const nightGlass = Color(0xFF0B1630); // CaptionInk.nightSky
  static const nightHalo = Color(0x990B1630); // night sky at 0.60

  // Day inks are deep: with no plate they sit on the day sky as the phone
  // draws it, a mid-tone (median L 0.15, clouds to 0.34), not on haze.
  static const dayInk = Color(0xFF141A27); // CaptionInk.dark
  static const dayInk2 = Color(0xFF1F2738); // dusk ink
  static const dayAccent = Color(0xFF132A55); // deepened zenith #3B78C9
  static const dayGlass = Color(0xFFE8EEF5); // CaptionInk.daySky
  static const dayHalo = Color(0xFFF4F7FB); // day haze, scaled by Halo strength
}

/// Colours for one sky. Text on the sky is inverse-colour
/// ([TypeScale.inverseText], owner 2026-10-30): it takes no ink from here,
/// only the [halo] solved for it ([solveHalo]). [ink], [ink2] and [accent]
/// colour the glyphs, the cursor and the rules, and are the text pairs again
/// if inverse text is switched off; each reaches 4.5:1 over the sky behind
/// it, with a [Halo] solved for that where the sky alone is not enough.
@immutable
class Palette {
  const Palette({
    required this.ink,
    required this.ink2,
    required this.accent,
    required this.glass,
    required this.rimTop,
    required this.rimSide,
    required this.selection,
    required this.halo,
  });

  /// Main text: warm paper white at night, deep blue-black by day.
  final Color ink;

  /// Hints, notes, units: moonlit grey at night, dusk ink by day.
  final Color ink2;

  /// The one accent (cursor, handles, focus, the primary action): the
  /// blue-white of the brightest stars at night, deep zenith blue by day.
  final Color accent;

  /// The sky's own colour: the surface of popups (tooltips, the copy and
  /// paste toolbar). Text on the sky has no surface.
  final Color glass;

  /// The 1 px light edge, brightest on top where the light falls.
  final Color rimTop, rimSide;

  /// Selected text background (behind [ink]).
  final Color selection;

  /// The opposite ink, for the soft halo text on the open sky carries only
  /// where the sky behind it is too close to [ink] ([Halo]).
  final Color halo;

  /// Field baselines and table rules (non-text, 3:1 or more on the glass).
  Color get rule => ink2;

  /// Every text colour that must reach 4.5:1.
  List<Color> get texts => [ink, ink2, accent];

  static const night = Palette(
    ink: SkyColors.nightInk,
    ink2: SkyColors.nightInk2,
    accent: SkyColors.nightAccent,
    glass: SkyColors.nightGlass,
    rimTop: Color(0x38F5F2EA), // ink at 0.22
    rimSide: Color(0x14F5F2EA), // ink at 0.08
    selection: Color(0x47C5D4FF), // accent at 0.28
    halo: SkyColors.nightHalo,
  );

  static const day = Palette(
    ink: SkyColors.dayInk,
    ink2: SkyColors.dayInk2,
    accent: SkyColors.dayAccent,
    glass: SkyColors.dayGlass,
    rimTop: Color(0xB3FFFFFF), // white at 0.70
    rimSide: Color(0x59FFFFFF), // white at 0.35
    selection: Color(0x40132A55), // accent at 0.25
    halo: SkyColors.dayHalo,
  );

  /// [night] at 0, [day] at 1.
  static Palette lerp(Palette a, Palette b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    Color c(Color x, Color y) => Color.lerp(x, y, t)!;
    return Palette(
      ink: c(a.ink, b.ink),
      ink2: c(a.ink2, b.ink2),
      accent: c(a.accent, b.accent),
      glass: c(a.glass, b.glass),
      rimTop: c(a.rimTop, b.rimTop),
      rimSide: c(a.rimSide, b.rimSide),
      selection: c(a.selection, b.selection),
      halo: c(a.halo, b.halo),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Palette &&
      other.ink == ink &&
      other.ink2 == ink2 &&
      other.accent == accent &&
      other.glass == glass &&
      other.rimTop == rimTop &&
      other.rimSide == rimSide &&
      other.selection == selection &&
      other.halo == halo;

  @override
  int get hashCode => Object.hash(ink, ink2, accent, glass, rimTop, rimSide, selection, halo);
}

/// WCAG 2.2 contrast ratio of two opaque colours, 1..21.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Bundled families (assets/fonts, SIL OFL 1.1; docs/UI_PLAN.md
/// "Typography decision 2026-10-29").
abstract final class Fonts {
  /// Illunis speaks in Newsreader (variable wght and opsz).
  static const serif = 'Newsreader';

  /// You and the controls speak in Source Sans 3 (variable wght).
  static const sans = 'SourceSans3';
}

/// The one type scale for text on the sky, largest first. Sizes and line
/// heights in logical px, tracking in px. The serif sets its optical size to
/// the step's size, so the reply keeps sturdy strokes at 18 px and the title
/// gets finer ones at 28. Figures are lining in both families, and tabular
/// in the sans steps that hold numbers (log columns align). Every step draws
/// inverse-colour text ([inverseText]): the colour a step is given is kept
/// only for the fallback.
///
/// Inverse text by night needs no lighter base: over the near-black sky the
/// stroke is near white (halo_test: 6.1:1 over the brightest upper night sky
/// sampled, 9.7:1 where the reply sits, 8.2:1 over the moon, all with no
/// halo). It is weakest over a mid-tone, whose inverse is a mid-tone; the
/// light day halo carries the day sky (the median reads 4.0 to 4.5:1 with
/// the full halo at [inverseOpacity] 0.8).
///
/// | Step   | Family        | Size / line                 | wght | Tracking |
/// |---------|---------------|-----------------------------|------|----------|
/// | display | Newsreader    | 28 / 34                     | 400  | -0.2     |
/// | caption | Newsreader    | 26 / 36 (voice mode)        | 400  | 0        |
/// | reply   | Newsreader    | 22 / 30, 20 / 27, 18 / 25   | 420  | 0        |
/// | body    | Source Sans 3 | 16 / 24                     | 420  | 0        |
/// | label   | Source Sans 3 | 14 / 20                     | 600  | +0.2     |
/// | note    | Source Sans 3 | 13 / 18                     | 460  | +0.2     |
abstract final class TypeScale {
  /// The reply's fit ladder: size and line height, largest first.
  static const replySteps = [(22.0, 30.0), (20.0, 27.0), (18.0, 25.0)];

  /// The floor for [reply]; every other step stops at [floor].
  static const replyFloor = 18.0;
  static const floor = 13.0;

  static const _lnum = [FontFeature.liningFigures()];
  static const _tnum = [FontFeature.tabularFigures()];

  static TextStyle _style(String family, double size, double line, double wght, Color color,
          {double tracking = 0, List<FontFeature>? features}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        height: line / size,
        fontVariations: [
          FontVariation('wght', wght),
          // Newsreader's optical size axis runs 6 to 72.
          if (family == Fonts.serif) FontVariation('opsz', size.clamp(6, 72).toDouble()),
        ],
        fontWeight: FontWeight.values[((wght / 100).round() - 1).clamp(0, 8)],
        letterSpacing: tracking,
        fontFeatures: features,
        // Inverse-colour text (owner, 2026-10-30): white at [inverseOpacity] through a difference blend, so each
        // stroke shows the opposite of the sky under it ([inverseOf]). The ink [color] is kept only for the
        // [inverseText] false fallback.
        color: inverseText ? null : color,
        foreground: inverseText ? inversePaint() : null,
      );

  /// Text on the sky is inverse-colour (owner decision, 2026-10-30): the default. False goes back to the
  /// palette inks.
  static const bool inverseText = true;

  /// The alpha of the white that is difference-blended over the sky (owner, 2026-10-30): clearly apart from
  /// the sky, softer than the full inverse. A stroke shows `a + d - 2ad` per channel over sky `d`.
  static const double inverseOpacity = 0.8;

  /// The most the white may be raised to over a mid-tone sky ([solveInk], readability pass 2026-10-30).
  static const double inverseMax = 1.0;

  /// The paint of inverse text: white at [opacity] ([inverseOpacity] unless the sky behind asks for more,
  /// [solveInk]), [BlendMode.difference].
  static Paint inversePaint([double opacity = inverseOpacity]) => Paint()
    ..color = Color.from(alpha: opacity, red: 1, green: 1, blue: 1)
    ..blendMode = BlendMode.difference;

  /// [style] with its inverse white at [opacity]; any other style as it is.
  static TextStyle atOpacity(TextStyle style, double opacity) =>
      isInverse(style) && style.foreground!.color.a != opacity ? style.copyWith(foreground: inversePaint(opacity)) : style;

  /// True when [style] draws inverse-colour text (tests and audits).
  static bool isInverse(TextStyle? style) => style?.foreground?.blendMode == BlendMode.difference;

  /// View titles, the breath phase: Newsreader 28 / 34.
  static TextStyle display(Color c) => _style(Fonts.serif, 28, 34, 400, c, tracking: -0.2, features: _lnum);

  /// A spoken caption on the open sky (voice mode): Newsreader 26 / 36, or
  /// Source Sans 3 Light with [sans]. [wght] overrides the step's weight.
  static TextStyle caption(Color c, {bool sans = false, double size = 26, double? wght}) => sans
      ? _style(Fonts.sans, size, size * 36 / 26, wght ?? 300, c)
      : _style(Fonts.serif, size, size * 36 / 26, wght ?? 400, c, features: _lnum);

  /// The AI reply: Newsreader 22 / 30, or a smaller [replySteps] size.
  static TextStyle reply(Color c, {double size = 22}) {
    final line = replySteps.firstWhere((s) => s.$1 == size, orElse: () => (size, size * 1.36)).$2;
    return _style(Fonts.serif, size, line, 420, c, features: _lnum);
  }

  /// Input text, the user's line, log rows, empty states: Source Sans 3
  /// 16 / 24.
  static TextStyle body(Color c, {bool tabular = false}) =>
      _style(Fonts.sans, 16, 24, 420, c, features: tabular ? _tnum : null);

  /// Actions, table headers, dates, timers: Source Sans 3 14 / 20.
  static TextStyle label(Color c) => _style(Fonts.sans, 14, 20, 600, c, tracking: 0.2, features: _tnum);

  /// Sources, the disclaimer, a host name, the "advanced" tag: Source Sans 3
  /// 13 / 18.
  static TextStyle note(Color c) => _style(Fonts.sans, 13, 18, 460, c, tracking: 0.2, features: _tnum);
}

/// Text sits straight on the sky, with no plate behind it (owner,
/// 2026-10-29). Where the sky behind a block of text is too close to its
/// ink (the moon at night, a mid-blue zenith or dusk), the text carries a
/// soft halo in the opposite ink ([Palette.halo]), only as strong as
/// contrast needs: two zero-offset shadows, a tight one that lifts the
/// stroke edge and a wide one that lets it fade into the sky. Never a box
/// and never a gradient panel.
abstract final class Halo {
  /// Shadow blur radii, logical px.
  static const double tight = 2, wide = 8;

  /// How much of the halo colour sits right beside a stroke at full
  /// strength, as a fraction of the shadows' own alpha ([alpha]). Measured,
  /// not guessed: halo_test renders every step with the halo over flat skies
  /// and reads the pixels next to the strokes (0.45 to 0.51, night and day,
  /// readability pass 2026-10-30); this is the smallest it found, rounded
  /// down. Weaker halos reach relatively further (the three layers saturate
  /// least), so the full-strength share is the safe one.
  static const double reach = 0.44;

  /// Strength with no look at the sky (no SkyLight: tests, voice builds).
  static const double unknown = 1;

  /// The shadows for [halo] at [strength] (0 none .. 1 full).
  static List<Shadow> shadows(Color halo, double strength) {
    if (strength <= 0) return const [];
    final c = halo.withValues(alpha: alpha(halo, strength));
    // Readability pass (owner, 2026-10-30): a third, wider layer and a stronger edge, so dark ink keeps its letters over
    // deep blue patches of the day sky. Over white cloud the edge is invisible.
    return [
      Shadow(color: c, blurRadius: tight),
      Shadow(color: c, blurRadius: wide),
      Shadow(color: c, blurRadius: wider),
    ];
  }

  /// Edge strength multiplier over the measured [reach] (readability pass).
  static const double boost = 1.6;
  static const double wider = 16;

  /// The alpha each shadow of [halo] at [strength] is drawn with: the
  /// halo's own alpha times [strength] and [boost], at most 1.
  static double alpha(Color halo, double strength) => (halo.a * strength.clamp(0.0, 1.0) * boost).clamp(0.0, 1.0);

  /// The sky right beside a stroke of text with [halo] at [strength] over
  /// [sky]: what the ink is read against.
  static Color behind(Color halo, double strength, Color sky) =>
      Color.alphaBlend(halo.withValues(alpha: alpha(halo, strength) * reach), sky);

  /// How much of the halo colour lies under a stroke at full strength, as a
  /// fraction of [alpha]: what inverse text inverts. Measured like [reach]
  /// (halo_test reads the stroke cores): 0.82 to 0.93, night and day, the
  /// smallest rounded down.
  static const double cover = 0.8;

  /// The colour under a stroke of text with [halo] at [strength] over [sky]:
  /// inverse text shows [inverseOf] this.
  static Color under(Color halo, double strength, Color sky) =>
      Color.alphaBlend(halo.withValues(alpha: alpha(halo, strength) * cover), sky);
}

/// What a stroke of inverse text ([TypeScale.inverseText]) shows over
/// [under]: white at [opacity] through a difference blend, `a + d - 2ad` per
/// sRGB channel, as the GPU blends it. Opaque.
Color inverseOf(Color under, {double opacity = TypeScale.inverseOpacity}) {
  double ch(double d) => (opacity + d - 2 * opacity * d).clamp(0.0, 1.0);
  return Color.from(alpha: 1, red: ch(under.r), green: ch(under.g), blue: ch(under.b));
}

/// The contrast of text with [p]'s halo at [strength] over [sky], for each
/// text: one figure for inverse text (the stroke, white at [opacity], over
/// what is under it, against the sky beside it), else each of
/// [Palette.texts] against the sky beside it.
List<double> textContrasts(Palette p, double strength, Color sky, {double opacity = TypeScale.inverseOpacity}) {
  if (TypeScale.inverseText) return [inverseContrast(p.halo, strength, sky, opacity: opacity)];
  final beside = Halo.behind(p.halo, strength, sky);
  return [for (final t in p.texts) contrast(t, beside)];
}

/// The contrast of inverse text (white at [opacity]) with [halo] at
/// [strength] over [sky]: the stroke over what is under it, against the sky
/// beside it.
double inverseContrast(Color halo, double strength, Color sky, {double opacity = TypeScale.inverseOpacity}) =>
    contrast(inverseOf(Halo.under(halo, strength, sky), opacity: opacity), Halo.behind(halo, strength, sky));

/// The halo strengths [solveHalo] and [solveInk] try, none to full.
final _strengths = [for (var i = 0; i <= 20; i++) i / 20];

/// The inverse white's opacities [solveInk] tries, [TypeScale.inverseOpacity] up to [TypeScale.inverseMax].
final _opacities = [
  for (var a = TypeScale.inverseOpacity; a <= TypeScale.inverseMax + 1e-9; a += 0.05) double.parse(a.toStringAsFixed(2)),
];

/// The weakest halo, in steps of 0.05 from none, at which every text of [p]
/// reaches [target] over every colour of [skies], with the inverse white at
/// [opacity]; 1 (full) when even that does not, which is as far as a soft
/// halo goes. With inverse text the halo can also hurt (a dark halo under
/// strokes over the moon): the search from none stops at the first strength
/// that reaches the target.
double solveHalo(Palette p, List<Color> skies,
    {double target = GlassSpec.target + GlassSpec.margin, double opacity = TypeScale.inverseOpacity}) {
  for (final s in _strengths) {
    if (skies.every((sky) => textContrasts(p, s, sky, opacity: opacity).every((c) => c >= target))) return s;
  }
  return 1;
}

/// How inverse text is drawn over a stretch of sky ([solveInk]): the white
/// at [opacity], the halo in [halo] at [strength], and the least contrast
/// the model expects over the skies it was solved for.
@immutable
class SkyInkFit {
  const SkyInkFit({required this.opacity, required this.halo, required this.strength, this.least = double.infinity});

  final double opacity;
  final Color halo;
  final double strength;
  final double least;

  /// The owner's look (white at [TypeScale.inverseOpacity]) with [halo] at [strength]: no look at the sky.
  const SkyInkFit.plain(this.halo, this.strength) : opacity = TypeScale.inverseOpacity, least = double.infinity;

  /// The shadows that draw the halo.
  List<Shadow> get shadows => Halo.shadows(halo, strength);

  /// [a] to [b] at [t], for easing between two looks at the sky.
  static SkyInkFit lerp(SkyInkFit a, SkyInkFit b, double t) => SkyInkFit(
        opacity: a.opacity + (b.opacity - a.opacity) * t,
        halo: Color.lerp(a.halo, b.halo, t)!,
        strength: a.strength + (b.strength - a.strength) * t,
        least: b.least,
      );

  @override
  bool operator ==(Object other) =>
      other is SkyInkFit && other.opacity == opacity && other.halo == halo && other.strength == strength;

  @override
  int get hashCode => Object.hash(opacity, halo, strength);

  @override
  String toString() => 'SkyInkFit(opacity $opacity, halo $halo at $strength, least $least)';
}

/// The inverse white and the halo for text over [skies] (the darkest and
/// brightest sky the probe sampled under it), readability pass 2026-10-30.
/// [halos] are the halo colours to try, the one the text's palette chose
/// first. The owner's white ([TypeScale.inverseOpacity]) with the weakest
/// halo that reaches [target] wherever that is enough (the night, the deep
/// blue, white cloud, the moon). Over a mid-tone sky, whose inverse is a
/// mid-tone too, the white is raised in steps of 0.05, up to
/// [TypeScale.inverseMax], to the lowest opacity at which some halo
/// reaches the target; only then is the other halo colour tried. When
/// nothing reaches it, the opacity, colour and strength with the best
/// worst case.
SkyInkFit solveInk(List<Color> halos, List<Color> skies, {double target = GlassSpec.target + GlassSpec.margin}) {
  double least(Color halo, double s, double a) =>
      skies.map((sky) => inverseContrast(halo, s, sky, opacity: a)).fold(double.infinity, math.min);
  SkyInkFit? best;
  for (final halo in halos) {
    for (final a in _opacities) {
      for (final s in _strengths) {
        final l = least(halo, s, a);
        if (l >= target) return SkyInkFit(opacity: a, halo: halo, strength: s, least: l);
        if (best == null || l > best.least + 1e-9) best = SkyInkFit(opacity: a, halo: halo, strength: s, least: l);
      }
    }
  }
  return best ?? SkyInkFit.plain(halos.first, Halo.unknown);
}

/// The 4 px grid.
abstract final class Space {
  static const double s4 = 4, s8 = 8, s12 = 12, s24 = 24, s32 = 32;

  /// Side gutter.
  static const double gutter = 16;

  /// Horizontal inset inside glass.
  static const double inset = 20;

  /// Smallest touch target.
  static const double target = 48;
}

/// Two radii and no pills: nothing is rounded by 0.4 x its height or more.
abstract final class Radii {
  static const double glass = 18;
  static const double control = 8;

  /// The largest radius a shape [height] tall may have.
  static double maxFor(double height) => height * 0.4;
}

/// Slow, organic motion (owner amendment A2). With reduced motion only
/// opacity changes, in at most [reduced].
abstract final class Motion {
  /// A pressed control's ink overlay.
  static const press = Duration(milliseconds: 120);
  static const pressCurve = Curves.linear;

  /// An exchange fading in, glass growing to fit.
  static const enter = Duration(milliseconds: 420);
  static const enterCurve = Curves.easeOutCubic;
  static const exit = Duration(milliseconds: 240);
  static const exitCurve = Curves.easeInCubic;

  /// A view opening (fade and a [viewRise] px rise) and closing.
  static const viewIn = Duration(milliseconds: 520);
  static const viewOut = Duration(milliseconds: 320);
  static const viewCurve = Curves.easeOutCubic;
  static const double viewRise = 12;

  /// A halo (once the glass tint) strengthening or fading as the sky
  /// behind the text changes.
  static const glass = Duration(milliseconds: 900);
  static const glassCurve = Curves.easeInOutSine;

  /// The ink turning from night to day (or back) with the sun.
  static const ink = Duration(milliseconds: 2400);
  static const inkCurve = Curves.easeInOutSine;

  /// The longest opacity fade with reduced motion.
  static const reduced = Duration(milliseconds: 120);
}

/// The contrast target, and the tint model of the glass plates that text
/// sat on until 2026-10-29 (UI_PLAN 3.2). No widget paints a plate now;
/// [target] and [margin] drive [solveHalo], [sigma] smooths [SkyProbe]'s
/// look at the sky, and SkyLight.glassAlpha still answers in these terms.
abstract final class GlassSpec {
  /// Backdrop blur sigma, logical px.
  static const double sigma = 14;

  /// Tint alpha bounds. The floor keeps a trace of the glass; the cap is
  /// the most of the sky any surface may hide.
  static const double alphaFloor = 0.06;
  static const double alphaMax = 0.86;

  /// Contrast every text pair must reach on the glass, with a margin for
  /// the sky moving between two looks at it.
  static const double target = 4.5;
  static const double margin = 0.3;

  /// Before the sky has been looked at (first frames, voice builds): the
  /// model alphas from the plan. [unknown] also applies with no SkyLight.
  static const double modelNight = 0.40, modelDay = 0.45, modelTwilight = 0.65, unknown = 0.80;
}
