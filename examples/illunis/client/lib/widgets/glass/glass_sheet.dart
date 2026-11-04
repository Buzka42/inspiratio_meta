/// A view's region over the sky (logs, breathwork, the placeholder): it
/// starts just under the status bar and runs to the bottom edge, and its
/// header carries the title with Close at the top right. There is no sheet
/// to see: the view's text sits straight on the sky in the day or night
/// inks, with the halo its [GlassPanel] solves where the sky needs one.
library;

import 'package:flutter/material.dart';

import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';
import 'glass_actions.dart';
import 'glass_surface.dart';

class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(Space.gutter, Space.s8, Space.s8, 0)});

  final Widget child;

  /// Inside the region. The right side is smaller so Close's 48 px target
  /// keeps its word on the 16 px gutter.
  final EdgeInsets padding;

  static const radius = BorderRadius.vertical(top: Radius.circular(Radii.glass));

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + Space.s8),
          child: GlassPanel(
            borderRadius: radius,
            child: SafeArea(top: false, child: Padding(padding: padding, child: child)),
          ),
        ),
      );
}

/// The title in display type and Close as a word at the top right.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, required this.onClose, this.closeKey});

  final String title;
  final VoidCallback onClose;
  final Key? closeKey;

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: Space.s8),
          child: Semantics(header: true, child: Text(title, style: TypeScale.display(p.ink))),
        ),
      ),
      GlassTextAction('Close', onClose, key: closeKey),
    ]);
  }
}
