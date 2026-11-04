import 'package:flutter/foundation.dart';

import '../moon/moon_view.dart';
import '../moon/voice_zoom.dart';
import '../moon_render/moon_controller.dart';
import 'reflection_geometry.dart';

/// How far the moon in the main view is zoomed and turned.
///
/// Zoom 1 is the sky shader's own disc size; zoom [maxZoom] makes the disc
/// [maxZoom] times larger in the sky (and so in its reflection). The turn
/// (selenographic centre) lives on [moon]'s view, whose own zoom stays 1:
/// the main view sizes the disc itself.
class MoonFocus extends ChangeNotifier {
  MoonFocus({this.moon, double maxZoom = 12}) : zoomView = MoonView(maxZoom: maxZoom) {
    moon?.addListener(notifyListeners); // default map loaded, tiles
  }

  /// Imagery for the textured disc; null draws the sky shader's moon only.
  final MoonController? moon;
  final MoonView zoomView;

  double get zoom => zoomView.zoom;
  double get angularRadius => moonAngularRadius(zoom);

  void beginPinch() => zoomView.beginPinch();

  /// [scale] is cumulative since [beginPinch].
  void updatePinch(double scale) {
    final before = zoom;
    zoomView.updatePinch(scale);
    if (zoom != before) notifyListeners();
  }

  /// Turns the moon by a drag of ([dx], [dy]) over a disc of [radius], all
  /// in the same screen units.
  void drag(double dx, double dy, double radius) {
    final m = moon;
    if (m == null || radius <= 0) return;
    m.view.pan(dx, dy, MoonScreen(2 * radius, 2 * radius));
    notifyListeners();
  }

  /// Applies a spoken moon command. True when [transcript] was one.
  bool handleTranscript(String transcript) {
    final action = parseMoonZoom(transcript);
    if (action == null) return false;
    zoomView.apply(action);
    if (action == MoonZoomAction.reset) moon?.view.centreOn(0, 0);
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    moon?.removeListener(notifyListeners);
    super.dispose();
  }
}
