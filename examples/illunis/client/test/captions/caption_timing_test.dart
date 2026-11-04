import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/captions/caption_style.dart';
import 'package:illunis_client/captions/caption_timing.dart';

void main() {
  group('captionWordCount', () {
    test('counts words, ignores punctuation and extra spaces', () {
      expect(captionWordCount(''), 0);
      expect(captionWordCount('   '), 0);
      expect(captionWordCount('Good morning'), 2);
      expect(captionWordCount('  Good   morning ,  sky — 7 '), 4);
    });
  });

  group('captionHold', () {
    test('4 s plus 0.3 s per word', () {
      expect(captionHold('one'), const Duration(milliseconds: 4300));
      expect(captionHold('a b c d e'), const Duration(milliseconds: 5500));
      // The research example: a 12-word line stays about 7 s.
      expect(captionHold(List.filled(12, 'w').join(' ')), const Duration(milliseconds: 7600));
    });

    test('clamps to the min and max hold', () {
      expect(captionHold(''), captionMinHold);
      expect(captionHold(List.filled(200, 'w').join(' ')), captionMaxHold);
    });

    test('26 words is under the cap, 27 hits it', () {
      expect(captionHold(List.filled(26, 'w').join(' ')), const Duration(milliseconds: 11800));
      expect(captionHold(List.filled(27, 'w').join(' ')), captionMaxHold);
    });
  });

  group('fade length', () {
    test('default is 1.5 s and requests clamp to 1.2..1.8 s', () {
      expect(captionFade, const Duration(milliseconds: 1500));
      expect(clampCaptionFade(const Duration(milliseconds: 100)), captionMinFade);
      expect(clampCaptionFade(const Duration(seconds: 5)), captionMaxFade);
      expect(clampCaptionFade(const Duration(milliseconds: 1400)),
          const Duration(milliseconds: 1400));
    });

    test('reduced motion uses the short fade', () {
      expect(captionExitDuration(CaptionExit.quickFade), captionQuickFade);
      expect(captionExitDuration(CaptionExit.dissolve), captionFade);
      expect(captionExitDuration(CaptionExit.fade, fade: const Duration(seconds: 9)),
          captionMaxFade);
    });
  });

  group('selectCaptionExit', () {
    test('shader ready, motion allowed, fog on: dissolve', () {
      expect(selectCaptionExit(shaderReady: true, disableAnimations: false), CaptionExit.dissolve);
    });
    test('shader unavailable: plain fade', () {
      expect(selectCaptionExit(shaderReady: false, disableAnimations: false), CaptionExit.fade);
    });
    test('reduced motion: quick fade, even with the shader ready', () {
      expect(selectCaptionExit(shaderReady: true, disableAnimations: true), CaptionExit.quickFade);
      expect(selectCaptionExit(shaderReady: false, disableAnimations: true), CaptionExit.quickFade);
    });
    test('fog off: plain fade', () {
      expect(selectCaptionExit(shaderReady: true, disableAnimations: false, fog: false),
          CaptionExit.fade);
    });
  });

  group('ink contrast (WCAG 1.4.3, 4.5:1)', () {
    const paleSkies = [Color(0xFFFFFFFF), Color(0xFFE8EEF5), Color(0xFFDDE6F0), Color(0xFF8FB3D9)];
    const nightSkies = [Color(0xFF0B1630), Color(0xFF223A5E), Color(0xFF000000)];

    test('dark ink reads on pale and mid day sky', () {
      for (final s in paleSkies) {
        expect(contrastRatio(CaptionInk.dark.color, s), greaterThanOrEqualTo(4.5), reason: '$s');
      }
    });
    test('pale ink reads on night sky', () {
      for (final s in nightSkies) {
        expect(contrastRatio(CaptionInk.pale.color, s), greaterThanOrEqualTo(4.5), reason: '$s');
      }
    });
    test('forBackground picks the readable preset', () {
      expect(CaptionInk.forBackground(const Color(0xFFE8EEF5)), CaptionInk.dark);
      expect(CaptionInk.forBackground(const Color(0xFF0B1630)), CaptionInk.pale);
    });
    test('contrast ratio is symmetric and bounded', () {
      const b = Color(0xFF000000), w = Color(0xFFFFFFFF);
      expect(contrastRatio(b, w), closeTo(21, 0.01));
      expect(contrastRatio(w, b), contrastRatio(b, w));
      expect(contrastRatio(w, w), 1);
    });
  });

  test('caption style uses the bundled families with a wght variation (and opsz in the serif)', () {
    final serif = captionTextStyle();
    expect(serif.fontFamily, 'Newsreader');
    expect(serif.fontVariations, [const FontVariation('wght', 400), const FontVariation('opsz', 26)]);
    final sans = captionTextStyle(font: CaptionFont.sans);
    expect(sans.fontFamily, 'SourceSans3');
    expect(sans.fontWeight, FontWeight.w300);
  });
}
