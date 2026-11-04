import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_camera.dart';
import 'package:illunis_client/sky/sky_shader.dart';
import 'package:illunis_client/sky/sky_state.dart';

const _n = 200;
const _focal = 3000.0; // sun radius about 14 px

ResolvedScene _at(DateTime utc) =>
    CelestialScene.resolve(SkyState.at(utc, latitudeDeg: 52.2, longitudeDeg: 21.0));

/// sky.frag aimed so the sun sits at the centre of a 200 px square.
Future<Uint8List> _render(WidgetTester t, SkyShader shader, ResolvedScene s) async {
  final bytes = await t.runAsync(() async {
    final fs = shader.newShader();
    final u = SkyShader.uniforms(
      scene: s,
      camera: SkyCamera(size: const Size(_n + 0.0, _n + 0.0), azimuthRad: s.sunAzimuthRad),
      time: 0,
    );
    u[2] = _n / 2;
    u[3] = _n / 2 + 2 * _focal * math.tan(s.sunAltitudeRad / 2);
    u[4] = _focal;
    for (var i = 0; i < u.length; i++) {
      fs.setFloat(i, u[i]);
    }
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, _n + 0.0, _n + 0.0), Paint()..shader = fs);
    final img = await rec.endRecording().toImage(_n, _n);
    final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    return d!.buffer.asUint8List();
  });
  return bytes!;
}

/// Mean RGB at [r] px right of the centre, over a 3 px vertical strip.
List<double> _at3(Uint8List b, int r) {
  final out = [0.0, 0.0, 0.0];
  for (var dy = -1; dy <= 1; dy++) {
    final o = ((_n ~/ 2 + dy) * _n + _n ~/ 2 + r) * 4;
    for (var c = 0; c < 3; c++) {
      out[c] += b[o + c] / 255 / 3;
    }
  }
  return out;
}

double _sum(List<double> c) => c[0] + c[1] + c[2];

void main() {
  testWidgets('day sun: saturated disc and a glare that falls off', (t) async {
    final s = _at(DateTime.utc(2026, 10, 24, 11));
    expect(s.sunAltitudeRad * radToDeg, inInclusiveRange(15, 35));
    final shader = await t.runAsync(SkyShader.load);
    expect(shader, isNotNull);
    final b = await _render(t, shader!, s);
    final centre = _at3(b, 0), edge = _at3(b, 25), mid = _at3(b, 40), far = _at3(b, 95);
    expect(_sum(centre), greaterThan(2.9), reason: 'disc $centre');
    expect(_sum(edge), greaterThan(_sum(mid) + 0.02), reason: 'glare $edge vs $mid');
    expect(_sum(mid), greaterThanOrEqualTo(_sum(far)), reason: '$mid vs $far');
  });

  testWidgets('low sun: reddened by the air, darker at the limb', (t) async {
    final s = _at(DateTime.utc(2026, 10, 24, 15, 8));
    expect(s.sunAltitudeRad * radToDeg, inInclusiveRange(0.5, 4));
    final shader = await t.runAsync(SkyShader.load);
    expect(shader, isNotNull);
    final b = await _render(t, shader!, s);
    final centre = _at3(b, 0), limb = _at3(b, 12); // r = 14 px, AA edge from 12.6
    expect(centre[0], greaterThan(centre[2] + 0.1), reason: 'red over blue $centre');
    // Inside the edge, so only limb darkening lowers the unsaturated green.
    expect(centre[1], greaterThan(limb[1] + 0.01), reason: 'limb $centre vs $limb');
  });
}
