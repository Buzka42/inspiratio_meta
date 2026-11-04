/// Graphic modes and the voice intents that switch them. Pure Dart.
enum GraphicMode { reflection, classic }

class ModeController {
  ModeController({GraphicMode initial = GraphicMode.reflection}) : _mode = initial;

  GraphicMode _mode;
  final _listeners = <void Function(GraphicMode)>[];

  GraphicMode get mode => _mode;

  void addListener(void Function(GraphicMode) l) => _listeners.add(l);
  void removeListener(void Function(GraphicMode) l) => _listeners.remove(l);

  void set(GraphicMode m) {
    if (m == _mode) return;
    _mode = m;
    for (final l in List.of(_listeners)) {
      l(m);
    }
  }

  /// Applies a spoken phrase. Returns true when it was a mode command.
  bool handleUtterance(String text) {
    final m = parseModeIntent(text);
    if (m == null) return false;
    set(m);
    return true;
  }
}

/// Maps a transcript to a mode, or null. Case, punctuation and filler ignored.
GraphicMode? parseModeIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z\s]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (RegExp(r'\bshow( me)?( the)? sky\b').hasMatch(t)) return GraphicMode.classic;
  if (RegExp(r'\bshow( me)?( the)? (water|lake|reflection)\b').hasMatch(t)) {
    return GraphicMode.reflection;
  }
  return null;
}
