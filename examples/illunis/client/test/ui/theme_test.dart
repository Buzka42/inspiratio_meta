// The theme leaves no Material default showing (UI_PLAN S5): the field's
// cursor, selection and handles are the token accent and selection, there
// is no ripple, and tooltip text is the sans.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/ui/theme.dart';
import 'package:illunis_client/ui/tokens.dart';

void main() {
  for (final (name, p, day) in [('night', Palette.night, false), ('day', Palette.day, true)]) {
    testWidgets('$name: a TextField takes the token cursor, selection and handle colours', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: illunisTheme(p, day: day),
        home: const Material(child: TextField(key: ValueKey('f'))),
      ));
      await t.tap(find.byType(TextField));
      await t.pump();
      final editable = t.widget<EditableText>(find.byType(EditableText));
      expect(editable.cursorColor, p.accent);
      expect(editable.selectionColor, p.selection);
      final ctx = t.element(find.byKey(const ValueKey('f')));
      expect(TextSelectionTheme.of(ctx).selectionHandleColor, p.accent);
      expect(Theme.of(ctx).splashFactory, NoSplash.splashFactory);
      expect(Theme.of(ctx).colorScheme.primary, p.accent);
    });
  }

  testWidgets('tooltip text is the sans on the glass colour', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: illunisTheme(Palette.night, day: false),
      home: const Center(child: Tooltip(message: 'Send', child: SizedBox.square(dimension: 48))),
    ));
    await t.longPress(find.byType(Tooltip));
    await t.pump(const Duration(milliseconds: 300));
    final rich = t.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText() == 'Send');
    expect(rich.text.style?.fontFamily, Fonts.sans);
    // Inverse-colour text, over the glass colour of the tooltip.
    expect(TypeScale.isInverse(rich.text.style), isTrue);
  });

  test('buttons use the small control radius and no splash', () {
    final theme = illunisTheme(Palette.day, day: true);
    final shape = theme.textButtonTheme.style!.shape!.resolve({}) as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(Radii.control));
    expect(theme.textButtonTheme.style!.splashFactory, NoSplash.splashFactory);
    expect(theme.textTheme.bodyMedium!.fontFamily, Fonts.sans);
  });
}
