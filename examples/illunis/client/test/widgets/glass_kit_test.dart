// The glass kit (UI_PLAN UI-1, owner amendments A1 and A3, and no plates
// since 2026-10-29): text regions with no surface whose halo follows the sky
// behind them, one field, one action row, thin line glyphs. Synthetic text
// only.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/ui/icons.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';
import 'package:illunis_client/widgets/glass/glass_actions.dart';
import 'package:illunis_client/widgets/glass/glass_field.dart';
import 'package:illunis_client/widgets/glass/glass_sheet.dart';
import 'package:illunis_client/widgets/glass/glass_surface.dart';

/// A 360 x 800 screen with an optional SkyLight and one glass panel at
/// [panel] (global).
Future<void> pumpPanel(WidgetTester t, {SkyLight Function(Widget child)? sky, Rect panel = const Rect.fromLTWH(16, 500, 328, 120)}) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final glass = Stack(children: [
    Positioned.fromRect(rect: panel, child: const GlassPanel(child: SizedBox.expand())),
  ]);
  await t.pumpWidget(MaterialApp(home: sky == null ? glass : sky(glass)));
  await t.pump();
}

double haloOf(WidgetTester t) => t.state<GlassPanelState>(find.byType(GlassPanel)).halo;
bool? darkOf(WidgetTester t) => t.state<GlassPanelState>(find.byType(GlassPanel)).dark;

void main() {
  // Owner, 2026-10-29: no plates under text. The panel paints nothing and
  // only decides how strong a soft halo its text needs (was: the tint alpha
  // of a glass plate).
  group('halo strength (model, before the sky has been looked at)', () {
    testWidgets('no SkyLight: full halo', (t) async {
      await pumpPanel(t);
      expect(haloOf(t), Halo.unknown);
    });

    testWidgets('none by night, the day model by day, with no disc behind', (t) async {
      await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, child: c));
      expect(haloOf(t), 0);
      await pumpPanel(t, sky: (c) => SkyLight(daylight: 1, palette: Palette.day, child: c));
      expect(haloOf(t), dayModel);
    });

    testWidgets('full with the moon behind the panel, and at dusk', (t) async {
      await pumpPanel(t,
          sky: (c) => SkyLight(
              daylight: 0, palette: Palette.night, discs: const [Rect.fromLTWH(170, 470, 24, 24)], child: c));
      expect(haloOf(t), 1);
      await pumpPanel(t, sky: (c) => SkyLight(daylight: 0.5, palette: Palette.night, child: c));
      expect(haloOf(t), 1);
    });
  });

  testWidgets('with a look at the sky: no halo over the dark night, a halo over the moon', (t) async {
    final dark = _probe((x, y) => const Color(0xFF0B1630));
    await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, probe: dark, child: c));
    expect(haloOf(t), 0);
    // The moon's edge across the top of the panel: the sky is still dark on
    // the whole, so pale ink, with a halo where the moon is.
    final edge = _probe((x, y) => y > 60 && y < 65 ? const Color(0xFFE0E0D8) : const Color(0xFF0B1630));
    await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, probe: edge, child: c));
    expect(darkOf(t), isFalse);
    expect(haloOf(t), greaterThan(0.5));
    // Moonlight behind the whole panel: the day palette and its light halo.
    // Inverse text reads on the moon itself bare, but the probe's soft edge
    // into the night is a mid-tone, whose inverse is a mid-tone too, so a
    // partial halo is solved for it (with fixed dark ink this was none).
    final moonlit = _probe((x, y) => y > 60 && y < 80 ? const Color(0xFFE0E0D8) : const Color(0xFF0B1630));
    await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, probe: moonlit, child: c));
    expect(darkOf(t), isTrue);
    final (lo, hi) = moonlit.range(const Rect.fromLTWH(16, 500, 328, 120))!;
    expect(solveHalo(Palette.day, [hi]), 0);
    expect(haloOf(t), solveHalo(Palette.day, [lo, hi]));
    expect(haloOf(t), inExclusiveRange(0, 1));
  });

  group('ink from the sky behind the panel', () {
    Future<Color?> inkOver(WidgetTester t, SkyLight Function(Widget child) sky) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final text = GlassPanel(child: Builder(builder: (c) => Text('Synthetic line', style: TextStyle(color: SkyLight.paletteOf(c).ink))));
      await t.pumpWidget(MaterialApp(home: Center(child: sky(text))));
      await t.pump();
      return t.renderObject<RenderParagraph>(find.text('Synthetic line')).text.style!.color;
    }

    testWidgets('pale ink on deep blue by day, dark ink on lit cloud by night sun', (t) async {
      final deep = _probe((x, y) => const Color(0xFF0E2139));
      expect(await inkOver(t, (c) => SkyLight(daylight: 1, palette: Palette.day, probe: deep, child: c)),
          Palette.night.ink);
      await t.pumpWidget(const SizedBox());
      final cloud = _probe((x, y) => const Color(0xFF919FA6));
      expect(await inkOver(t, (c) => SkyLight(daylight: 0, palette: Palette.night, probe: cloud, child: c)),
          Palette.day.ink);
    });

    testWidgets('a later change eases to the other ink over the ink motion', (t) async {
      final deep = _probe((x, y) => const Color(0xFF0E2139));
      final cloud = _probe((x, y) => const Color(0xFFB9C2C8));
      expect(await inkOver(t, (c) => SkyLight(daylight: 1, palette: Palette.day, probe: deep, child: c)),
          Palette.night.ink);
      final mid = await inkOver(t, (c) => SkyLight(daylight: 1, palette: Palette.day, probe: cloud, child: c));
      expect(mid, isNot(Palette.day.ink));
      expect(darkOf(t), isTrue);
      await t.pump(Motion.ink);
      expect(t.renderObject<RenderParagraph>(find.text('Synthetic line')).text.style!.color, Palette.day.ink);
    });

    testWidgets('no look at the sky yet: the palette from the sun', (t) async {
      expect(await inkOver(t, (c) => SkyLight(daylight: 1, palette: Palette.day, child: c)), Palette.day.ink);
      expect(darkOf(t), isNull);
    });
  });

  testWidgets('the halo reaches the text inside, and none where the sky does not need it', (t) async {
    Future<List<Shadow>?> shadowsOver(SkyLight Function(Widget child)? sky) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const text = GlassPanel(child: Text('Synthetic line'));
      await t.pumpWidget(MaterialApp(home: Center(child: sky == null ? text : sky(text))));
      await t.pump();
      return t.renderObject<RenderParagraph>(find.text('Synthetic line')).text.style!.shadows;
    }

    expect(await shadowsOver(null), Halo.shadows(Palette.night.halo, 1));
    final dark = _probe((x, y) => const Color(0xFF0B1630));
    expect(await shadowsOver((c) => SkyLight(daylight: 0, palette: Palette.night, probe: dark, child: c)), isEmpty);
  });

  testWidgets('one text region: a panel in a panel asserts', (t) async {
    await t.pumpWidget(const MaterialApp(home: GlassPanel(child: GlassPanel(child: SizedBox()))));
    expect(t.takeException(), isAssertionError);
  });

  testWidgets('no plate: no blur, no clip, no tint, no rim, no gradient under the text', (t) async {
    await pumpPanel(t);
    final panel = find.byType(GlassPanel);
    for (final type in [BackdropFilter, ClipRSuperellipse, ClipRRect, CustomPaint, DecoratedBox, ColoredBox]) {
      expect(find.descendant(of: panel, matching: find.byType(type)), findsNothing, reason: '$type');
    }
  });

  group('GlassActions', () {
    testWidgets('every cell is at least 48 x 48, with no pill, and calls back', (t) async {
      final said = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Material(
          child: Center(
            child: SizedBox(
              width: 320,
              child: GlassActions(actions: [
                GlassAction('Yes', () => said.add('Yes'), key: const ValueKey('y'), primary: true),
                GlassAction('No', () => said.add('No'), key: const ValueKey('n')),
              ]),
            ),
          ),
        ),
      ));
      for (final k in ['y', 'n']) {
        final s = t.getSize(find.byKey(ValueKey(k)));
        expect(s.height, greaterThanOrEqualTo(48));
        expect(s.width, greaterThanOrEqualTo(48));
        await t.tap(find.byKey(ValueKey(k)));
      }
      expect(said, ['Yes', 'No']);
      for (final w in t.widgetList<InkWell>(find.byType(InkWell))) {
        final shape = w.customBorder as RoundedRectangleBorder;
        expect((shape.borderRadius as BorderRadius).topLeft.x, lessThan(Radii.maxFor(48)));
      }
      // Both cells in label type and inverse colour, readable over any sky the way the reply is.
      for (final word in ['Yes', 'No']) {
        final style = t.widget<Text>(find.text(word)).style!;
        expect(TypeScale.isInverse(style), isTrue, reason: word);
        expect((style.fontFamily, style.fontSize), (Fonts.sans, 14), reason: word);
      }
      expect(find.byType(GlassPanel), findsNothing);
    });
  });

  group('GlassField', () {
    Future<List<String>> pumpField(WidgetTester t) async {
      final sent = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Material(
          child: GlassField(
            hint: 'Write to Illunis',
            fieldKey: const ValueKey('f'),
            sendKey: const ValueKey('s'),
            onSubmit: sent.add,
          ),
        ),
      ));
      return sent;
    }

    testWidgets('text and hint in inverse colour, body type, a rule baseline, the send glyph', (t) async {
      await pumpField(t);
      final field = t.widget<TextField>(find.byKey(const ValueKey('f')));
      expect(TypeScale.isInverse(field.decoration!.hintStyle), isTrue);
      expect(TypeScale.isInverse(field.style), isTrue);
      // What is drawn: the hint and the editable text, after Material's merges.
      expect(TypeScale.isInverse(t.widget<Text>(find.text('Write to Illunis')).style), isTrue);
      expect(TypeScale.isInverse(t.widget<EditableText>(find.byType(EditableText)).style), isTrue);
      expect(field.cursorColor, Palette.night.accent);
      expect(field.style!.fontSize, 16);
      expect(field.style!.fontFamily, Fonts.sans);
      expect(field.minLines, 1);
      expect(field.maxLines, 4);
      final base = t.widget<DecoratedBox>(find.byKey(const ValueKey('glass-field-baseline')));
      expect(((base.decoration as BoxDecoration).border as Border).bottom.color, Palette.night.rule);
      expect(find.descendant(of: find.byKey(const ValueKey('s')), matching: find.byType(IllunisIcon)), findsOneWidget);
    });

    testWidgets('send is inert and dim while the field is empty', (t) async {
      final sent = await pumpField(t);
      await t.tap(find.byKey(const ValueKey('s')));
      expect(sent, isEmpty);
      final dim = find.ancestor(of: find.byKey(const ValueKey('s')), matching: find.byType(AnimatedOpacity));
      expect(t.widget<AnimatedOpacity>(dim).opacity, GlassField.idleAlpha);
      expect(t.getSemantics(find.byKey(const ValueKey('s'))), isSemantics(hasEnabledState: true, isEnabled: false));
      await t.enterText(find.byKey(const ValueKey('f')), '   ');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('s')));
      expect(sent, isEmpty);
      await t.enterText(find.byKey(const ValueKey('f')), 'Synthetic line');
      await t.pump();
      expect(t.widget<AnimatedOpacity>(dim).opacity, 1);
      await t.tap(find.byKey(const ValueKey('s')));
      expect(sent, ['Synthetic line']);
    });

    testWidgets('Enter submits the trimmed text and clears the field', (t) async {
      final sent = await pumpField(t);
      await t.enterText(find.byKey(const ValueKey('f')), '  Synthetic line ');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump();
      expect(sent, ['Synthetic line']);
      expect(t.widget<TextField>(find.byKey(const ValueKey('f'))).controller!.text, isEmpty);
    });
  });

  testWidgets('a view sheet: one text region, the title, Close as a 48 px word at the top right',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var closed = 0, next = 0;
    await t.pumpWidget(MaterialApp(
      home: SkyLight(
        daylight: 1,
        palette: Palette.day,
        child: GlassSheet(
          child: Column(children: [
            SheetHeader(title: 'Food', onClose: () => closed++, closeKey: const ValueKey('close')),
            GlassGlyphAction(IllunisGlyph.forward, () => next++, key: const ValueKey('next'), label: 'Next day'),
          ]),
        ),
      ),
    ));
    await t.pump();
    expect(find.byType(GlassPanel), findsOneWidget);
    expect(t.widget<GlassPanel>(find.byType(GlassPanel)).borderRadius, GlassSheet.radius);
    final title = t.widget<Text>(find.text('Food')).style!;
    expect((title.fontFamily, title.fontSize, TypeScale.isInverse(title)), (Fonts.serif, 28, true));
    final close = t.getRect(find.byKey(const ValueKey('close')));
    expect(close.height, greaterThanOrEqualTo(48));
    expect(close.width, greaterThanOrEqualTo(48));
    expect(close.right, lessThanOrEqualTo(360 - 8));
    expect(close.top, lessThan(t.getRect(find.text('Food')).bottom));
    expect(t.widget<Text>(find.text('Close')).style!.fontFamily, Fonts.sans);
    await t.tap(find.byKey(const ValueKey('close')));
    expect(closed, 1);
    expect(t.getSize(find.byKey(const ValueKey('next'))), const Size(48, 48));
    await t.tap(find.byKey(const ValueKey('next')));
    expect(next, 1);
    expect(find.bySemanticsLabel('Next day'), findsOneWidget);
  });

  testWidgets('every glyph paints a thin stroke and nothing filled', (t) async {
    for (final g in IllunisGlyph.values) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      GlyphPainter(g, const Color(0xFFFFFFFF)).paint(canvas, const Size.square(20));
      final image = await t.runAsync(() => recorder.endRecording().toImage(20, 20));
      final bytes = (await t.runAsync(() => image!.toByteData()))!;
      var lit = 0;
      for (var i = 3; i < bytes.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) > 0) lit++;
      }
      // Lines, not shapes: well under half the 400 px are touched.
      expect(lit, greaterThan(10), reason: '$g');
      expect(lit, lessThan(200), reason: '$g');
    }
  });
}

SkyProbe _probe(Color Function(int x, int y) at) {
  const w = 45, h = 100;
  final b = ByteData(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = at(x, y);
      final i = (y * w + x) * 4;
      b
        ..setUint8(i, (c.r * 255).round())
        ..setUint8(i + 1, (c.g * 255).round())
        ..setUint8(i + 2, (c.b * 255).round())
        ..setUint8(i + 3, 255);
    }
  }
  return SkyProbe.fromRgba(b, w, h);
}
