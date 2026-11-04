// Text ink from the sky actually behind it: the mean relative luminance of
// the probe under the text picks pale or dark ink by the higher WCAG
// contrast, with hysteresis. Skies are the phone samples in docs/UI_PLAN.md
// ("Typography decision 2026-10-29").
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/captions/caption_style.dart';
import 'package:illunis_client/captions/caption_view.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';

const samples = {
  'day, deep blue p1': (Color(0xFF0E2139), false),
  'day, open blue p10': (Color(0xFF375565), false),
  'day, median': (Color(0xFF5D6D78), false),
  'day, lit cloud p99': (Color(0xFF919FA6), true),
  'night, reply area': (Color(0xFF12171D), false),
  'night, sky': (Color(0xFF0B1630), false),
};

double paleOn(double l) => contrastOnLuminance(SkyInk.pale, l);
double darkOn(double l) => contrastOnLuminance(SkyInk.dark, l);

SkyProbe flat(Color c, {int w = 45, int h = 100}) {
  final b = ByteData(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    b
      ..setUint8(i * 4, (c.r * 255).round())
      ..setUint8(i * 4 + 1, (c.g * 255).round())
      ..setUint8(i * 4 + 2, (c.b * 255).round())
      ..setUint8(i * 4 + 3, 255);
  }
  return SkyProbe.fromRgba(b, w, h);
}

Future<ui.FragmentProgram?> _noShader() async => null;

void main() {
  group('ink for a sky sample', () {
    for (final MapEntry(key: name, value: (sky, dark)) in samples.entries) {
      test(name, () {
        final l = sky.computeLuminance();
        final (p, d) = (paleOn(l), darkOn(l));
        final chosen = SkyInk.isDark(l);
        final ink = chosen ? d : p;
        // ignore: avoid_print
        print('$name ${_hex(sky)} L=${l.toStringAsFixed(3)} pale ${p.toStringAsFixed(1)} '
            'dark ${d.toStringAsFixed(1)} -> ${chosen ? 'dark' : 'pale'} ${ink.toStringAsFixed(1)}');
        expect(chosen, dark);
        expect(ink, greaterThanOrEqualTo(chosen ? p : d));
        if (p >= GlassSpec.target || d >= GlassSpec.target) expect(ink, greaterThanOrEqualTo(GlassSpec.target));
        expect(CaptionInk.forLuminance(l), dark ? CaptionInk.dark : CaptionInk.pale);
        // Contrast from luminance matches contrast of the colours.
        expect(p, closeTo(contrast(SkyInk.pale, sky), 1e-9));
      });
    }

    test('every sky from black to white gets the better ink, and 4.5:1 where either reaches it', () {
      for (var i = 0; i <= 1000; i++) {
        final l = i / 1000;
        final (p, d) = (paleOn(l), darkOn(l));
        final ink = SkyInk.isDark(l) ? d : p;
        expect(ink, greaterThanOrEqualTo(p > d ? p : d), reason: 'L=$l');
      }
    });
  });

  group('hysteresis', () {
    test('the ink in use stays while the other is less than 1.5 times better and neither reaches 4.5', () {
      // L 0.20: dark 4.1, pale 3.7. L 0.17: pale 4.2, dark 3.6.
      expect(darkOn(0.20) / paleOn(0.20), lessThan(SkyInk.switchRatio));
      expect(SkyInk.isDark(0.20), isTrue);
      expect(SkyInk.isDark(0.20, wasDark: false), isFalse);
      expect(SkyInk.isDark(0.17), isFalse);
      expect(SkyInk.isDark(0.17, wasDark: true), isTrue);
    });

    test('switches when the other is 1.5 times better', () {
      expect(darkOn(0.30) / paleOn(0.30), greaterThanOrEqualTo(SkyInk.switchRatio));
      expect(SkyInk.isDark(0.30, wasDark: false), isTrue);
      expect(paleOn(0.05) / darkOn(0.05), greaterThanOrEqualTo(SkyInk.switchRatio));
      expect(SkyInk.isDark(0.05, wasDark: true), isFalse);
    });

    test('switches early when the ink in use is below 4.5 and the other reaches it', () {
      // L 0.23: pale 3.3, dark 4.6, only 1.4 times better.
      expect(darkOn(0.23) / paleOn(0.23), lessThan(SkyInk.switchRatio));
      expect(paleOn(0.23), lessThan(4.5));
      expect(darkOn(0.23), greaterThanOrEqualTo(4.5));
      expect(SkyInk.isDark(0.23, wasDark: false), isTrue);
    });

    test('a sky wavering around the crossing does not flicker', () {
      var dark = SkyInk.isDark(0.19);
      var flips = 0;
      for (var i = 0; i < 200; i++) {
        final next = SkyInk.isDark(0.19 + (i.isEven ? 0.025 : -0.025), wasDark: dark);
        if (next != dark) flips++;
        dark = next;
      }
      expect(flips, 0);
    });

    test('a sweep up and back switches once each way, the way back lower', () {
      bool? dark;
      double? up, down;
      for (var i = 0; i <= 100; i++) {
        final next = SkyInk.isDark(i / 200, wasDark: dark);
        if (dark == false && next) up ??= i / 200;
        dark = next;
      }
      for (var i = 100; i >= 0; i--) {
        final next = SkyInk.isDark(i / 200, wasDark: dark);
        if (dark == true && !next) down ??= i / 200;
        dark = next;
      }
      expect(up, isNotNull);
      expect(down, isNotNull);
      expect(down!, lessThan(up!));
      // ignore: avoid_print
      print('switch to dark at L=$up, back to pale at L=$down');
    });

    test('CaptionInk keeps its ink the same way', () {
      expect(CaptionInk.forLuminance(0.20, current: CaptionInk.pale), CaptionInk.pale);
      expect(CaptionInk.forLuminance(0.20, current: CaptionInk.dark), CaptionInk.dark);
      expect(CaptionInk.forLuminance(0.30, current: CaptionInk.pale), CaptionInk.dark);
    });
  });

  test('probe mean luminance under a rect', () {
    // Left half white, right half black, no blur at this scale.
    final b = ByteData(8 * 8 * 4);
    for (var i = 0; i < 64; i++) {
      final v = i % 8 < 4 ? 255 : 0;
      b
        ..setUint8(i * 4, v)
        ..setUint8(i * 4 + 1, v)
        ..setUint8(i * 4 + 2, v)
        ..setUint8(i * 4 + 3, 255);
    }
    final probe = SkyProbe.fromRgba(b, 8, 8, scale: 1, sigma: 0);
    expect(probe.meanLuminance(const Rect.fromLTWH(0, 0, 8, 8)), closeTo(0.5, 1e-6));
    expect(probe.meanLuminance(const Rect.fromLTWH(0, 0, 4, 8)), closeTo(1, 1e-6));
    expect(probe.meanLuminance(const Rect.fromLTWH(100, 100, 4, 4)), isNull);
  });

  group('caption ink from the sky behind it', () {
    Future<Color?> captionInk(WidgetTester t, {SkyProbe? probe, bool follow = true, CaptionInk ink = CaptionInk.dark}) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: SkyLight(
          daylight: 1,
          palette: Palette.day,
          probe: probe,
          child: CenteredCaption(
              child: CaptionView(text: 'Low tide', ink: ink, followSky: follow, programLoader: _noShader)),
        ),
      ));
      await t.pump();
      return _haloOf(t);
    }

    testWidgets('pale ink on deep blue by day, dark on lit cloud', (t) async {
      expect(await captionInk(t, probe: flat(const Color(0xFF0E2139))), _halo(CaptionInk.pale));
      await t.pumpWidget(const SizedBox());
      expect(await captionInk(t, probe: flat(const Color(0xFF919FA6)), ink: CaptionInk.pale), _halo(CaptionInk.dark));
    });

    testWidgets('no look at the sky, or not following it: the given ink', (t) async {
      expect(await captionInk(t), _halo(CaptionInk.dark));
      await t.pumpWidget(const SizedBox());
      expect(await captionInk(t, probe: flat(const Color(0xFF0E2139)), follow: false), _halo(CaptionInk.dark));
    });

    testWidgets('a later sky change eases to the other ink', (t) async {
      expect(await captionInk(t, probe: flat(const Color(0xFF0E2139))), _halo(CaptionInk.pale));
      await captionInk(t, probe: flat(const Color(0xFFB9C2C8)));
      await t.pump(const Duration(seconds: 2));
      expect(_haloOf(t), _halo(CaptionInk.dark));
    });
  });
}

/// The caption's text is inverse-colour (TypeScale.inverseText); the ink
/// the sky chose shows in its halo, so the halo colour is what is read.
Color? _haloOf(WidgetTester t) {
  final style = t.renderObject<RenderParagraph>(find.text('Low tide')).text.style!;
  expect(TypeScale.isInverse(style), isTrue);
  return style.shadows!.first.color;
}

Color _halo(CaptionInk ink) => ink.shadows.first.color;

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
