import 'package:flutter/painting.dart';

import '../ui/sky_light.dart' show SkyInk;
import '../ui/tokens.dart';

/// Caption families, from the one type scale ([TypeScale.caption]).
enum CaptionFont {
  /// Newsreader, Illunis's voice.
  serif(Fonts.serif, 400),

  /// Source Sans 3 Light, the sans alternative.
  sans(Fonts.sans, 300);

  const CaptionFont(this.family, this.weight);
  final String family;

  /// Default wght axis value (both files are variable fonts).
  final double weight;
}

/// Ink and halo for a caption, from the tokens. [dark] is for pale (day)
/// sky, [pale] for night. Both meet WCAG 1.4.3 4.5:1 on their intended sky
/// without counting the halo; the halo only separates the ink from the moon
/// or a busy cloud edge, and only [CaptionView] draws it.
class CaptionInk {
  const CaptionInk._(this.color, this.halo);
  final Color color;
  final Color halo;

  /// Deep blue-black ink: 17:1 on white, 6.4:1 on the grey of a lit cloud
  /// (#919FA6).
  static const dark = CaptionInk._(SkyColors.dayInk, SkyColors.dayHalo);

  /// Warm paper white for night sky: 15:1 or more on #0B1630.
  static const pale = CaptionInk._(SkyColors.nightInk, SkyColors.nightHalo);

  /// The preset with the higher contrast against [sky].
  static CaptionInk forBackground(Color sky) =>
      contrastRatio(dark.color, sky) >= contrastRatio(pale.color, sky) ? dark : pale;

  /// Reference skies for [forDaylight]: deep night blue and pale day haze.
  static const nightSky = SkyColors.nightGlass;
  static const daySky = SkyColors.dayGlass;

  /// Ink for a sky [daylight] of the way from night (0) to day (1), via a
  /// stand-in sky colour between [nightSky] and [daySky]. The fallback until
  /// the sky has been looked at ([forLuminance]).
  static CaptionInk forDaylight(double daylight) =>
      forBackground(Color.lerp(nightSky, daySky, daylight.clamp(0.0, 1.0))!);

  /// Ink for the sky actually behind the text, of mean relative luminance
  /// [sky], keeping [current] unless the other ink is clearly better
  /// ([SkyInk.isDark]).
  static CaptionInk forLuminance(double sky, {CaptionInk? current}) =>
      SkyInk.isDark(sky, wasDark: current == null ? null : current == dark) ? dark : pale;

  /// The soft halo in the opposite ink ([Halo]), at full strength: it carries
  /// the caption where neither ink reaches 4.5:1 on the sky behind it, and
  /// before the sky has been looked at.
  List<Shadow> get shadows => Halo.shadows(halo, 1);
}

/// WCAG 2.2 contrast ratio of two opaque colours, 1..21.
double contrastRatio(Color a, Color b) => contrast(a, b);

/// Caption text style for [font] and [ink] ([TypeScale.caption]): tracking
/// 0 and no shadow (the halo is the caption's own, [CaptionView] adds it).
TextStyle captionTextStyle({
  CaptionFont font = CaptionFont.serif,
  CaptionInk ink = CaptionInk.dark,
  double fontSize = 26,
  double? weight,
}) =>
    TypeScale.caption(ink.color, sans: font == CaptionFont.sans, size: fontSize, wght: weight ?? font.weight);
