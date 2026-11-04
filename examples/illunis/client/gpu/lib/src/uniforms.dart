import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'heightfield.dart';
import 'sky_detail.dart';
import 'water_camera.dart';

// std140 packing for the shader uniform blocks. Every member is a vec4, so
// offsets are 16 * index with no padding. Keep the order in step with the
// blocks in shaders/sim_step.frag and shaders/water_surface.frag.

/// SimInfo: size, wave, drops[4] (24 floats).
Float32List packSimInfo(int w, int h, WaveParams p, List<Drop> drops) {
  if (drops.length > maxDropsPerStep) {
    throw ArgumentError('at most $maxDropsPerStep drops per step');
  }
  final f = Float32List(24);
  f.setAll(0, [w.toDouble(), h.toDouble(), 1 / w, 1 / h]);
  f.setAll(4, [p.k, p.damping, p.spongeWidth, p.spongeStrength]);
  for (var i = 0; i < drops.length; i++) {
    final d = drops[i];
    f.setAll(8 + i * 4, [d.x, d.y, d.radius, d.strength]);
  }
  return f;
}

/// FrameInfo: screen, cam, domain, sim, look, moonDir, moonRight, moonUp,
/// stars, sun, sunLight, day, cloud, wind, cirrus, plates, nightMoon, night (72 floats). [stillness] is 0 (mirror calm) to 1 (rough, the look
/// before the uniform existed); look.yzw carry [moon]'s baked halo, exposure
/// and glow. [moon] null turns the per-pixel moon off;
/// [starGrid] (cols, rows) zero turns the per-pixel stars off. [pixelRad] is
/// the angle of one screen pixel at the centre.
///
/// Day: [sun] null or its dayFade 0, with no [SkyClouds.night], leaves
/// sun..night all zero, and the shader skips its sky block. Night clouds
/// ([SkyClouds.night] with fade > 0) fill the cloud fields without a sun:
/// nightMoon = moon dir xyz, moonLight; night = fade, 0, 0, 0. [clouds] need a sun; their wind offsets are
/// taken at [time] and wrapped (SkyClouds.layerOffsets). [cloudPlateSize]
/// > 0 (the plates' side in texels) switches the shader to the cloud
/// plates: cloud.w = that size, and the four sample offsets
/// (SkyClouds.plateOffsets, 0..2) go to wind.xy (A1), plates.xy (A2),
/// cirrus.zw (B1) and plates.zw (B2).
Float32List packFrameInfo({
  required int width,
  required int height,
  required double time,
  required double loudness,
  required WaterCamera camera,
  required double vignette,
  required Rect domain,
  required int simW,
  required int simH,
  required double heightScale,
  required double detail,
  double stillness = 1,
  SkyMoon? moon,
  (int, int) starGrid = (0, 0),
  double pixelRad = 0,
  double grain = 0,
  SkySun? sun,
  SkyClouds? clouds,
  int cloudPlateSize = 0,
}) =>
    Float32List.fromList([
      width.toDouble(), height.toDouble(), time, loudness.clamp(0.0, 1.0),
      camera.height, camera.pitch, camera.fovScale, vignette.clamp(0.0, 1.0),
      domain.left, domain.top, domain.right, domain.bottom,
      simW.toDouble(), simH.toDouble(), heightScale, detail.clamp(0.0, 1.0),
      stillness.clamp(0.0, 1.0), moon?.bakedHalo ?? 0, moon?.exposure ?? 0, moon?.glow ?? 0,
      ..._v(moon?.dir), moon == null ? 0 : math.tan(moon.angularRadius),
      ..._v(moon?.right), moon?.discFraction ?? 0,
      ..._v(moon?.up), grain,
      starGrid.$1.toDouble(), starGrid.$2.toDouble(), pixelRad, 0,
      ..._day(sun, clouds, time, cloudPlateSize),
    ]);

List<double> _day(SkySun? sun, SkyClouds? clouds, double time, int plateSize) {
  final dayOn = sun != null && sun.dayFade > 0;
  final n = clouds?.night;
  final nightOn = n != null && n.fade > 0;
  if (!dayOn && !nightOn) return List<double>.filled(36, 0);
  final c = clouds;
  final o = c?.layerOffsets(time) ?? const [0.0, 0, 0, 0, 0, 0];
  final usePlates = plateSize > 0 && c != null;
  final pl = usePlates ? c.plateOffsets(time) : List<double>.filled(8, 0);
  final s = dayOn ? sun : null;
  return [
    ..._v(s?.dir), math.max(s?.angularRadius ?? 0, 0),
    ..._v(s?.colour), (s?.intensity ?? 0).clamp(0.0, 1.0),
    (s?.dayFade ?? 0).clamp(0.0, 1.0), (c?.tier ?? 0).clamp(0, 1).toDouble(),
    (c?.shadow ?? 0).clamp(0.0, 1.0), 1 / SkyClouds.tilePeriod,
    (c?.coverage ?? 0).clamp(0.0, 1.0), math.max(c?.density ?? 0, 0),
    c == null ? 0 : math.max(c.height, 0) / SkyClouds.tilePeriod, usePlates ? plateSize.toDouble() : 0.0,
    usePlates ? pl[0] : o[0], usePlates ? pl[1] : o[1], o[2], o[3],
    o[4], o[5], pl[4], pl[5],
    pl[2], pl[3], pl[6], pl[7],
    ..._v(nightOn ? n.moonDir : null), nightOn ? n.moonLight.clamp(0.0, 1.0) : 0.0,
    nightOn ? n.fade.clamp(0.0, 1.0) : 0.0, 0, 0, 0,
  ];
}

List<double> _v((double, double, double)? v) => v == null ? const [0, 0, 0] : [v.$1, v.$2, v.$3];
