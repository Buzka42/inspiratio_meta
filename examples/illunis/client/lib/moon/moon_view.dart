import 'dart:math' as math;

import 'voice_zoom.dart';

/// Screen size in physical pixels. At zoom 1 the moon disc has radius
/// [fitRadius], so the whole moon fits the default view.
class MoonScreen {
  const MoonScreen(this.width, this.height, {this.fitFraction = 1.0});

  final double width;
  final double height;

  /// Share of the short side the disc fills at zoom 1.
  final double fitFraction;

  double get fitRadius => math.min(width, height) / 2 * fitFraction;
}

/// Zoom and centre of the moon view. Pure state; no rendering.
///
/// zoom 1.0 = whole moon fits; larger = zoomed in. The centre is the
/// selenographic point under the screen centre, in degrees.
class MoonView {
  MoonView({this.minZoom = 1.0, double maxZoom = 1.0, this.voiceStep = 1.5})
    : assert(minZoom > 0, 'minZoom must be positive'),
      assert(voiceStep > 1, 'voiceStep must be above 1'),
      _maxZoom = math.max(minZoom, maxZoom),
      _zoom = minZoom;

  final double minZoom;

  /// Zoom factor of one voice step.
  final double voiceStep;

  double _maxZoom;
  double _zoom;
  double _longitudeDeg = 0;
  double _latitudeDeg = 0;
  double _pinchStartZoom = 1;

  double get maxZoom => _maxZoom;
  double get zoom => _zoom;
  double get longitudeDeg => _longitudeDeg;
  double get latitudeDeg => _latitudeDeg;

  /// Changes the upper bound (for example after a screen rotation).
  set maxZoom(double value) {
    _maxZoom = math.max(minZoom, value);
    _zoom = _clamp(_zoom);
  }

  /// Call when a pinch starts.
  void beginPinch() => _pinchStartZoom = _zoom;

  /// Continuous zoom from a pinch; [scale] is cumulative since [beginPinch]
  /// (Flutter's ScaleUpdateDetails.scale).
  void updatePinch(double scale) {
    if (scale.isFinite && scale > 0) _zoom = _clamp(_pinchStartZoom * scale);
  }

  /// Continuous zoom by an incremental factor.
  void pinchBy(double factor) {
    if (factor.isFinite && factor > 0) _zoom = _clamp(_zoom * factor);
  }

  /// Drags the moon by a screen delta in pixels. Dragging right brings the
  /// western side into view; dragging down brings the north into view.
  void pan(double dxPx, double dyPx, MoonScreen screen) {
    if (!dxPx.isFinite || !dyPx.isFinite) return;
    final radius = screen.fitRadius * _zoom;
    if (radius <= 0) return;
    const deg = 180 / math.pi;
    _longitudeDeg = _wrap(_longitudeDeg - dxPx / radius * deg);
    _latitudeDeg = (_latitudeDeg + dyPx / radius * deg).clamp(-90.0, 90.0);
  }

  void zoomIn() => _zoom = _clamp(_zoom * voiceStep);
  void zoomOut() => _zoom = _clamp(_zoom / voiceStep);

  void reset() {
    _zoom = minZoom;
    _longitudeDeg = 0;
    _latitudeDeg = 0;
  }

  void apply(MoonZoomAction action) => switch (action) {
    MoonZoomAction.zoomIn => zoomIn(),
    MoonZoomAction.zoomOut => zoomOut(),
    MoonZoomAction.reset => reset(),
  };

  /// Points the view at a selenographic position (degrees).
  void centreOn(double longitudeDeg, double latitudeDeg) {
    _longitudeDeg = _wrap(longitudeDeg);
    _latitudeDeg = latitudeDeg.clamp(-90.0, 90.0);
  }

  double _clamp(double z) {
    final c = z.clamp(minZoom, _maxZoom);
    // Snap float noise so repeated steps land exactly on the bounds.
    if ((c - _maxZoom).abs() < 1e-9) return _maxZoom;
    if ((c - minZoom).abs() < 1e-9) return minZoom;
    return c;
  }

  static double _wrap(double lon) {
    final w = (lon + 180) % 360 - 180;
    return w == -180 ? 180 : w;
  }
}
