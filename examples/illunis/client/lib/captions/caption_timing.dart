/// Caption timing and exit choice. Pure, so it is testable without a widget
/// tree. Values are provisional until tested on the Blade (PLAN.md,
/// "Decisions approved 2026-10-24").
library;

/// How a caption leaves the screen.
enum CaptionExit {
  /// Shader dissolve: glyphs break up and drift upward as mist.
  dissolve,

  /// Plain opacity fade over [captionFade].
  fade,

  /// Reduced motion: a short opacity change, no movement.
  quickFade,
}

/// Base hold before the dissolve starts.
const Duration captionBaseHold = Duration(seconds: 4);

/// Extra hold per word.
const Duration captionPerWord = Duration(milliseconds: 300);

/// Hold bounds: an empty line still shows for the base hold; a very long
/// line does not pin the sky for minutes.
const Duration captionMinHold = captionBaseHold;
const Duration captionMaxHold = Duration(seconds: 12);

/// Dissolve or fade length (research range 1.2 to 1.8 s).
const Duration captionFade = Duration(milliseconds: 1500);
const Duration captionMinFade = Duration(milliseconds: 1200);
const Duration captionMaxFade = Duration(milliseconds: 1800);

/// Reduced-motion opacity change.
const Duration captionQuickFade = Duration(milliseconds: 300);

/// Words separated by whitespace; punctuation-only tokens do not count.
int captionWordCount(String text) => text
    .split(RegExp(r'\s+'))
    .where((w) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(w))
    .length;

/// Hold = 4 s + 0.3 s per word, clamped to [captionMinHold, captionMaxHold].
Duration captionHold(String text) {
  final ms = captionBaseHold.inMilliseconds +
      captionPerWord.inMilliseconds * captionWordCount(text);
  return Duration(
      milliseconds:
          ms.clamp(captionMinHold.inMilliseconds, captionMaxHold.inMilliseconds));
}

/// Clamps a requested fade length to the approved 1.2 to 1.8 s window.
Duration clampCaptionFade(Duration d) => Duration(
    milliseconds: d.inMilliseconds
        .clamp(captionMinFade.inMilliseconds, captionMaxFade.inMilliseconds));

/// Exit choice. Reduced motion wins over everything; the shader dissolve
/// needs the program loaded and the fog setting on.
CaptionExit selectCaptionExit({
  required bool shaderReady,
  required bool disableAnimations,
  bool fog = true,
}) {
  if (disableAnimations) return CaptionExit.quickFade;
  if (!shaderReady || !fog) return CaptionExit.fade;
  return CaptionExit.dissolve;
}

/// Exit length for [exit]; [fade] is clamped to the approved window.
Duration captionExitDuration(CaptionExit exit, {Duration fade = captionFade}) =>
    exit == CaptionExit.quickFade ? captionQuickFade : clampCaptionFade(fade);
