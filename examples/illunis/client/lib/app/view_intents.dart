import '../core/mode_controller.dart';
import 'moon_focus.dart';

final _mode = RegExp(
    r'^(?:(?:switch|change|go) (?:to|into) |use )?(?:the )?(classic|reflection|water) (?:mode|view)$');

/// Mode phrases the main view adds to [parseModeIntent]: "classic mode",
/// "switch to reflection mode", "use the water view". Null when not one.
GraphicMode? parseViewModeIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z\s]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^(please |can you |could you )'), '')
      .replaceFirst(RegExp(r' please$'), '');
  final m = _mode.firstMatch(t);
  if (m != null) return m.group(1) == 'classic' ? GraphicMode.classic : GraphicMode.reflection;
  return parseModeIntent(t);
}

/// The main view's voice commands, handled before a transcript becomes a
/// server turn: moon zoom ("zoom in on the moon") first, then the mode
/// switch between Classic and Reflection. Reflection is the default.
///
/// Passed to AppController as its ModeController, so a matched command never
/// reaches the server and the voice session ends the turn as for a mode
/// change.
class ViewModeController extends ModeController {
  ViewModeController({required this.focus, super.initial});

  final MoonFocus focus;

  @override
  bool handleUtterance(String text) {
    if (focus.handleTranscript(text)) return true;
    final m = parseViewModeIntent(text);
    if (m == null) return false;
    set(m);
    return true;
  }
}
