/// A row of equal text actions (Yes / No, Save, Keep mine / Use, Pause /
/// Stop): cells at least 48 px tall in label type, split by faint
/// hairlines, with no shape of their own. They sit on the sky, with the
/// halo of the [GlassPanel] they are in. The words are inverse-colour text
/// like the reply ([TypeScale.inverseText]), so the primary cell and the
/// others look alike. A press shows an 8 % ink veil, no ripple.
library;

import 'package:flutter/material.dart';

import '../../ui/icons.dart';
import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';
import 'glass_surface.dart';

class GlassAction {
  const GlassAction(this.label, this.onPressed, {this.key, this.primary = false});
  final String label;
  final VoidCallback onPressed;
  final Key? key;
  final bool primary;
}

class GlassActions extends StatelessWidget {
  const GlassActions({super.key, required this.actions, this.topRule = false});

  final List<GlassAction> actions;

  /// A hairline across the top, when the row forms a glass's bottom edge.
  final bool topRule;

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    final hair = 1 / (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
    final cells = <Widget>[];
    for (final (i, a) in actions.indexed) {
      if (i > 0) {
        cells.add(Container(key: const ValueKey('glass-actions-rule'), width: hair, color: p.rimSide));
      }
      cells.add(Expanded(child: _Cell(action: a, palette: p)));
    }
    final row = IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
    );
    if (!topRule) return row;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.rimSide, width: hair))),
      child: row,
    );
  }
}

/// One text action on its own (Close at the top right of a view): the same
/// cell as in [GlassActions], as wide as its word.
class GlassTextAction extends StatelessWidget {
  const GlassTextAction(this.label, this.onPressed, {super.key, this.primary = false});
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) => _Cell(
        action: GlassAction(label, onPressed, primary: primary),
        palette: SkyLight.paletteOf(context),
        expand: false,
      );
}

/// One glyph action in a 48 px target (previous / next day), with its
/// spoken label.
class GlassGlyphAction extends StatelessWidget {
  const GlassGlyphAction(this.glyph, this.onPressed, {super.key, required this.label});
  final IllunisGlyph glyph;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          highlightColor: p.ink.withValues(alpha: 0.08),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
          child: SizedBox.square(dimension: Space.target, child: Center(child: IllunisIcon(glyph, color: p.ink))),
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.action, required this.palette, this.expand = true});
  final GlassAction action;
  final Palette palette;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final color = action.primary ? palette.accent : palette.ink;
    // Material below resets DefaultTextStyle, so the halo is passed here.
    // Outside a GlassPanel (the breathwork controls) there is no panel halo: use the sky halo for the palette, so the
    // words stay readable over white cloud (readability pass, 2026-10-30).
    final panel = TextHalo.of(context);
    final shadows = panel.isNotEmpty ? panel : Halo.shadows(palette.halo, 1);
    final style = TypeScale.label(color).copyWith(shadows: shadows);
    final text = Text(action.label, textAlign: TextAlign.center, style: style);
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: action.key,
          onTap: action.onPressed,
          highlightColor: palette.ink.withValues(alpha: 0.08),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Space.target, minWidth: Space.target),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s12),
              child: expand ? Center(child: text) : Center(widthFactor: 1, child: text),
            ),
          ),
        ),
      ),
    );
  }
}
