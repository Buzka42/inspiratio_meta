import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/moon_view.dart';
import 'package:illunis_client/moon/voice_zoom.dart';

void main() {
  const screen = MoonScreen(1080, 2400);

  test('pinch clamps at min and max', () {
    final v = MoonView(maxZoom: 3);
    v.beginPinch();
    v.updatePinch(0.2);
    expect(v.zoom, 1.0);
    v.updatePinch(100);
    expect(v.zoom, 3.0);
    v.pinchBy(0.01);
    expect(v.zoom, 1.0);
    v.pinchBy(1e6);
    expect(v.zoom, 3.0);
  });

  test('pinch is continuous, not snapped', () {
    final v = MoonView(maxZoom: 3);
    v.beginPinch();
    v.updatePinch(1.37);
    expect(v.zoom, closeTo(1.37, 1e-12));
    v.updatePinch(1.371);
    expect(v.zoom, closeTo(1.371, 1e-12));
  });

  test('ignores non-finite or non-positive scales', () {
    final v = MoonView(maxZoom: 3)..pinchBy(2);
    v.pinchBy(double.nan);
    v.pinchBy(-1);
    v.pinchBy(0);
    expect(v.zoom, 2);
  });

  test('voice zoom steps and clamps', () {
    final v = MoonView(maxZoom: 3, voiceStep: 1.5);
    v.apply(MoonZoomAction.zoomIn);
    expect(v.zoom, closeTo(1.5, 1e-12));
    v.apply(MoonZoomAction.zoomIn);
    expect(v.zoom, closeTo(2.25, 1e-12));
    v.apply(MoonZoomAction.zoomIn);
    expect(v.zoom, 3.0);
    v.apply(MoonZoomAction.zoomOut);
    expect(v.zoom, closeTo(2.0, 1e-12));
    for (var i = 0; i < 5; i++) {
      v.zoomOut();
    }
    expect(v.zoom, 1.0);
  });

  test('reset restores zoom and centre', () {
    final v = MoonView(maxZoom: 3)
      ..pinchBy(2)
      ..pan(200, -100, screen);
    expect(v.longitudeDeg, isNot(0));
    v.apply(MoonZoomAction.reset);
    expect(v.zoom, 1.0);
    expect(v.longitudeDeg, 0);
    expect(v.latitudeDeg, 0);
  });

  test('pan moves the centre and scales with zoom', () {
    final v = MoonView(maxZoom: 3);
    // Drag right by one disc radius: centre moves 1 radian west.
    v.pan(540, 0, screen);
    expect(v.longitudeDeg, closeTo(-57.2958, 1e-3));
    v.reset();
    v.pinchBy(2);
    v.pan(540, 0, screen);
    expect(v.longitudeDeg, closeTo(-28.6479, 1e-3));
    // Drag down brings the north into view; latitude clamps at the pole.
    v.pan(0, 1e6, screen);
    expect(v.latitudeDeg, 90);
  });

  test('longitude wraps', () {
    final v = MoonView()..centreOn(190, 0);
    expect(v.longitudeDeg, closeTo(-170, 1e-9));
  });

  test('lowering max zoom re-clamps', () {
    final v = MoonView(maxZoom: 3)..pinchBy(3);
    v.maxZoom = 2;
    expect(v.zoom, 2);
    v.maxZoom = 0.5;
    expect(v.maxZoom, 1);
    expect(v.zoom, 1);
  });
}
