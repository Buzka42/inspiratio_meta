// Shared checks for the view audit tests: the real caption fonts (so text
// widths match the phone, not the square test font), a phone-sized surface,
// and a layout check that fails on any overflow or clipped text.
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const phone = Size(360, 780);

/// Loads the two bundled families (Fonts.sans, Fonts.serif) from
/// assets/fonts once per test file.
Future<void> loadCaptionFonts() async {
  for (final (family, path) in [
    ('SourceSans3', 'assets/fonts/source_sans_3/SourceSans3-VariableWght.ttf'),
    ('Newsreader', 'assets/fonts/newsreader/Newsreader-VariableOpszWght.ttf'),
  ]) {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

/// Sets the test surface to [size] logical px at 1x, reset after the test.
void phoneSurface(WidgetTester t, {Size size = phone}) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

/// No exception (a RenderFlex overflow is one), and every text on screen
/// fits: inside [width] horizontally, no line cut off by maxLines or by a
/// height smaller than the text, and no single word (a number such as
/// `1:45:30`) broken over two lines.
void expectFits(WidgetTester t, {double width = 360, String? reason}) {
  expect(t.takeException(), isNull, reason: reason);
  for (final r in t.allRenderObjects.whereType<RenderParagraph>()) {
    if (!r.attached || !r.hasSize || r.size.isEmpty) continue;
    final text = r.text.toPlainText();
    final why = '${reason ?? ''} "$text"';
    final box = MatrixUtils.transformRect(r.getTransformTo(null), Offset.zero & r.size);
    expect(box.left, greaterThanOrEqualTo(-0.5), reason: '$why starts off screen');
    expect(box.right, lessThanOrEqualTo(width + 0.5), reason: '$why runs off screen');
    expect(r.didExceedMaxLines, isFalse, reason: '$why is cut by maxLines');
    expect(r.getMaxIntrinsicHeight(r.size.width), lessThanOrEqualTo(r.size.height + 1), reason: '$why is clipped');
    if (!text.trim().contains(RegExp(r'\s'))) {
      expect(r.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(r.size.width + 0.5),
          reason: '$why breaks inside a word');
    }
  }
}
