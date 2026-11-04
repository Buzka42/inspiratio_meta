/// One plain sentence and one action, shown while exact alarms are off, on
/// its own clear glass in the app's inks (not mounted yet, UI_PLAN Q7).
/// There is no settings screen yet, so the caller supplies [onGrant]
/// (normally `coordinator.openExactAlarmSettings`).
library;

import 'package:flutter/material.dart';

import '../ui/sky_light.dart';
import '../ui/tokens.dart';
import '../widgets/glass/glass_actions.dart';
import '../widgets/glass/glass_surface.dart';

const exactAlarmNoticeText = 'To wake you on time, Illunis needs permission to set alarms.';
const exactAlarmNoticeButton = 'Allow alarms';

class ExactAlarmNotice extends StatelessWidget {
  const ExactAlarmNotice({super.key, required this.visible, required this.onGrant});

  /// Pass `coordinator.needsExactAlarmGrant`.
  final bool visible;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final p = SkyLight.paletteOf(context);
    return GlassPanel(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.inset, Space.gutter, Space.inset, Space.s12),
          child: Text(exactAlarmNoticeText, style: TypeScale.body(p.ink)),
        ),
        GlassActions(topRule: true, actions: [GlassAction(exactAlarmNoticeButton, onGrant, primary: true)]),
      ]),
    );
  }
}
