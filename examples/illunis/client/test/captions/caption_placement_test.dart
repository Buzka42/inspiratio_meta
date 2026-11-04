import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/captions/caption_style.dart';
import 'package:illunis_client/captions/caption_view.dart';

Future<ui.FragmentProgram?> _noShader() async => null;

void main() {
  for (final text in ['Low tide', 'The tide turns at dawn and the gulls go quiet over the long grey water']) {
    testWidgets('caption text is centred on the screen (${text.length} chars)', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: Colors.black),
          CenteredCaption(child: CaptionView(text: text, programLoader: _noShader)),
        ]),
      ));
      final screen = t.getRect(find.byType(Stack).first).center;
      final c = t.getRect(find.text(text)).center;
      expect((c - screen).distance, lessThan(3), reason: 'text centre $c, screen $screen');
    });
  }

  testWidgets('only the caption box takes taps, not the whole screen', (t) async {
    var below = 0;
    await t.pumpWidget(MaterialApp(
      home: Stack(fit: StackFit.expand, children: [
        GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => below++),
        const CenteredCaption(child: CaptionView(text: 'Low tide', programLoader: _noShader)),
      ]),
    ));
    await t.tapAt(const Offset(10, 10));
    expect(below, 1);
  });

  test('ink follows daylight: pale at night, dark by day', () {
    expect(CaptionInk.forDaylight(0), CaptionInk.pale);
    expect(CaptionInk.forDaylight(1), CaptionInk.dark);
    expect(CaptionInk.forDaylight(-1), CaptionInk.pale);
    expect(CaptionInk.forDaylight(2), CaptionInk.dark);
  });

  testWidgets('the base style has no halo and no tracking; the caption on the sky opts into its halo',
      (t) async {
    final base = captionTextStyle(ink: CaptionInk.pale);
    expect(base.shadows, isNull);
    expect(base.letterSpacing, 0);
    await t.pumpWidget(const MaterialApp(
      home: CenteredCaption(child: CaptionView(text: 'Low tide', ink: CaptionInk.pale, programLoader: _noShader)),
    ));
    final style = t.widget<Text>(find.text('Low tide')).style!;
    expect(style.shadows, CaptionInk.pale.shadows);
  });

  test('the old Captions widget is gone', () {
    expect(File('lib/widgets/captions.dart').existsSync(), isFalse);
    final uses = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => RegExp(r'\bCaptions\(|widgets/captions\.dart|class Captions\b')
            .hasMatch(f.readAsStringSync()))
        .map((f) => f.path)
        .toList();
    expect(uses, isEmpty);
  });
}
