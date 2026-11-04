/// Bakes the real sky (client/lib/sky) into the equirectangular image the
/// Reflection water samples, and draws the textured moon into it.
///
/// Two stages, so a moon zoom does not re-run the sky shader:
///   1. [bakeBaseSky]: sky.frag is drawn through a stereographic SkyCamera
///      that reaches past the zenith (one shader pass), then a triangle mesh
///      resamples that picture into equirectangular u/v, using the water
///      shaders' own lookup ([equirectDir]). The catalog stars are painted
///      straight into the equirect afterwards ([paintEquirectStars]): the
///      resample spread a 1-2 px star over several texels and lost most of
///      its contrast. Done when the clock moves the sky.
///   2. [composeSky]: the base image plus the moon disc, warped into the
///      same u/v by a second small mesh. Done when the zoom or turn changes.
///
/// A water port that draws the sky's detail per screen pixel (option B,
/// [WaterPort.drawsSkyDetail]) gets a base without stars, planets, the
/// shader's moon disc or its dither ([bakeBaseSky] with perPixelDetail),
/// plus [buildSkyDetail] and [renderMoonDisc] in place of stage 2. A 4096
/// px equirect texel covers 3 to 7 phone pixels, which is fine for the
/// smooth sky but showed stars, the moon and the grain as blocks.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:illunis_gpu/illunis_gpu.dart' show SkyDetail, SkyMoon;

import '../moon_render/moon_controller.dart';
import '../sky/celestial_math.dart';
import '../sky/celestial_scene.dart';
import '../sky/sky_camera.dart';
import '../sky/sky_painter.dart';
import '../sky/sky_shader.dart';
import '../sky/star_field.dart';
import 'moon_disc.dart';
import 'reflection_geometry.dart';

/// Debug-only diagnostic line; filter logcat with `illunis_diag`.
void bakeDiag(String m) {
  if (kDebugMode) debugPrint('illunis_diag: $m');
}

final _identity = Float64List.fromList(const [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

/// Sizes of the bake. The default keeps the equirect at 4096 x 2048 (as the
/// procedural placeholder was) and the stereographic picture at about
/// 3.3k x 1.8k (focal 700 px), which oversamples the zenith band the water
/// reflects. Tests pass a small config.
class SkyBakeConfig {
  const SkyBakeConfig({this.equirectWidth = 4096, this.focal = 700});
  final int equirectWidth;
  final double focal;

  int get equirectHeight => equirectWidth ~/ 2;

  /// Width of the stereographic picture: +-100 degrees of azimuth at the
  /// horizon. The equirect mesh covers all azimuths wherever this picture
  /// reaches, so high sky behind the camera is baked too.
  static const halfSpanDeg = 100.0;

  /// Altitude at the stereographic picture's top edge, past the zenith.
  /// 110 covers sky behind the camera down to 70 degrees elevation: option
  /// B (pitch 60) reflects the zenith region behind the camera at the bottom
  /// of the screen (azimuth near 180, elevation above about 80), which was
  /// the dark wedge when only +-100 degrees of azimuth were baked.
  static const topAltDeg = 110.0;
}

/// Stereographic camera for stage 1: forward at [azimuth], zenith inside.
SkyCamera bakeCamera(SkyBakeConfig c, double azimuth) {
  final f = c.focal;
  final above = f * 2 * math.tan(SkyBakeConfig.topAltDeg * degToRad / 2);
  final below = f * 0.14; // about 8 degrees of ground
  final h = (above + below).ceilToDouble();
  final halfW = f * 2 * math.tan(SkyBakeConfig.halfSpanDeg * degToRad / 2);
  return SkyCamera(
    size: ui.Size((2 * halfW).ceilToDouble(), h),
    azimuthRad: azimuth,
    horizonFraction: above / h,
    topAltitudeDeg: SkyBakeConfig.topAltDeg,
  );
}

/// Stage 1. [shader] null paints the sky's gradient fallback (no GPU shader).
Future<ui.Image> bakeBaseSky({
  required ResolvedScene scene,
  required double azimuth,
  required SkyShader? shader,
  SkyBakeConfig config = const SkyBakeConfig(),
  bool perPixelDetail = false,
  bool hideMoon = false,
}) async {
  final watch = Stopwatch()..start();
  final cam = bakeCamera(config, azimuth);
  final sw = cam.size.width.toInt(), sh = cam.size.height.toInt();
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  if (shader == null) {
    // The fallback lays its horizon at kHorizonFraction of the size given.
    SkyPainter.paintFallback(c, ui.Size(cam.size.width, cam.principal.dy / kHorizonFraction),
        scene.dayness);
  } else {
    final fs = shader.newShader();
    SkyShader.write(fs, scene: scene, camera: cam, time: 0);
    if (perPixelDetail) {
      for (final i in planetBrightnessSlots) {
        fs.setFloat(i, 0); // planets are drawn per pixel
      }
      // One dither value for the whole picture: the water adds its own
      // per screen pixel. (Also softens the sun's rim, unused at night.)
      fs.setFloat(43, 1e-6);
      // The textured moon covers this tiny remnant; the halo stays.
      if (hideMoon) fs.setFloat(19, 1e-3);
      // The water draws the sun disc per pixel (lib/app/day_sky.dart). The
      // atmosphere and its Mie glow around the sun are unchanged.
      fs.setFloat(sunRadiusSlot, perPixelSunRadius);
    }
    c.drawRect(ui.Offset.zero & cam.size, ui.Paint()..shader = fs);
  }
  final recordMs = watch.elapsedMilliseconds; // UI-thread recording only
  final stereo = await _rasterise(rec, sw, sh);

  final ew = config.equirectWidth, eh = config.equirectHeight;
  final rec2 = ui.PictureRecorder();
  final e = ui.Canvas(rec2);
  final full = ui.Rect.fromLTWH(0, 0, ew.toDouble(), eh.toDouble());
  e.drawRect(full, ui.Paint()..color = const ui.Color(0xFF060A16));
  e.drawRect(ui.Rect.fromLTRB(0, eh * 0.5, ew.toDouble(), eh.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF0A0B0E));
  final mesh = equirectMesh(cam, azimuth, ew, eh);
  if (mesh != null) {
    final v = mesh.toVertices();
    e.drawVertices(v, ui.BlendMode.srcOver, _imagePaint(stereo));
    v.dispose();
  }
  if (!perPixelDetail) paintEquirectStars(e, scene: scene, azimuth: azimuth, width: ew, height: eh);
  final out = await _rasterise(rec2, ew, eh);
  stereo.dispose();
  bakeDiag('sky_bake ${shader == null ? 'gradient_fallback' : 'shader'} ${ew}x$eh '
      'detail=${perPixelDetail ? 'per_pixel' : 'baked'}${hideMoon ? '_no_moon' : ''} '
      'sun_alt=${(scene.sunAltitudeRad * radToDeg).toStringAsFixed(1)} '
      'dayness=${scene.dayness.toStringAsFixed(2)} '
      'star_vis=${catalogStarVisibility(scene.sunAltitudeRad * radToDeg).toStringAsFixed(2)} '
      'moon_alt=${(scene.moonDir.altitude * radToDeg).toStringAsFixed(1)} '
      'mesh=${mesh != null} record_ms=$recordMs total_ms=${watch.elapsedMilliseconds}');
  debugDumpSky(out, 'sky_base');
  return out;
}

/// Star alpha gain and disc scale in the equirect. The water shows the bake
/// magnified (about 1.5 screen px per texel on a 1080 px wide phone, more on
/// a 1440 px flagship), bilinear-filtered and at 0.6-0.9 reflectance, which
/// cut the brightest stars to +0.10-0.15 above the moonlit sky on the phone.
const starGain = 1.6;
const starDiscScale = 1.4;

/// sky.frag uSunRadius index, and its value on the per-pixel path: 0, which
/// sky.frag reads as no disc. A tiny radius (as the moon's 1e-3) does not
/// work for the sun: its disc term is about 19000 x the sky's light, so any
/// stereo pixel inside even a 1e-3 rad remnant saturates (measured 0.99
/// against a 0.83 glow), and below about 3.5e-4 rad cos() rounds to 1 in
/// float and the shader's smoothstep edges meet.
const sunRadiusSlot = 20;
const perPixelSunRadius = 0.0;

/// sky.frag uniform indices of the five planets' brightness (uPlanetN.w).
const planetBrightnessSlots = [26, 30, 34, 38, 42];

/// Tint mix (0 blue-white .. 1 orange) per planet, in [Planet] order:
/// Mercury, Venus, Mars, Jupiter, Saturn (sky.frag's planet colours).
const _planetTint = [0.3, 0.15, 1.0, 0.45, 0.6];

/// Disc radius in logical pixels of a catalog star: bright stars keep
/// Classic's size order, faint ones are a point about 0.9 logical px wide.
double starRadiusLogical(double mag) => mag <= 1.9 ? 0.45 + brightStarSize(mag) * 0.32 : 0.44;

/// Per-pixel star alpha gain: a sharp disc covers far fewer pixels than the
/// magnified bake texel it replaces, so it needs a higher peak to read.
const perPixelStarGain = 1.5;

/// Stars and planets (water frame, camera facing [azimuth]) plus the night
/// grain amplitude, for a port that draws them per pixel. [moon] from
/// [renderMoonDisc].
/// [devicePixelRatio] turns the logical star sizes into screen pixels.
/// [driftRad] turns the stars and planets past the scene's sidereal time
/// (see siderealDriftRad); [moon] must already be drifted
/// ([driftedSkyMoon]).
SkyDetail buildSkyDetail(ResolvedScene scene, double azimuth,
    {SkyMoon? moon, double devicePixelRatio = 3, double driftRad = 0}) {
  final dpr = devicePixelRatio;
  final out = <double>[];
  void add(Vec3 world, double alpha, double radius, double tint) {
    final (x, y, z) = worldToWater(world.normalized, azimuth);
    out.addAll([x, y, z, alpha, radius, tint]);
  }

  forEachVisibleStar(scene, 0, (i, dir, alpha, mag, bv) {
    add(dir, (alpha * perPixelStarGain).clamp(0.0, 1.0), starRadiusLogical(mag) * dpr,
        starTintMix(bv));
  }, driftRad: driftRad);
  final stars = out.length ~/ SkyDetail.starStride;
  final planets = <String>[];
  for (final p in scene.planets) {
    final w = (p.brightness * p.visibility).clamp(0.0, 1.0);
    final dir = driftedDirection(p.dir, scene.latitudeRad, driftRad);
    if (w <= 0 || dir.y < 0) continue;
    final alpha = (0.5 + 2.2 * w).clamp(0.0, 1.0) * math.min(1.0, w * 20);
    add(dir, alpha, (0.6 + 0.5 * w) * dpr, _planetTint[p.planet.index]);
    planets.add('${p.planet.name}:${w.toStringAsFixed(2)}');
  }
  bakeDiag('sky_detail stars=$stars planets=[${planets.join(' ')}] dpr=$dpr');
  return SkyDetail(
    stars: Float32List.fromList(out),
    moon: moon,
    grain: (1 - scene.dayness) * (1.25 - scene.stillness) * 0.006,
  );
}

/// Linear exposure of the per-pixel moon disc before the surface pass's
/// soft shoulder. The picture's mean (about 0.39 linear) then shows near
/// 0.83 on screen after the calm-water reflectance (0.62), its highlands
/// near 0.9 and the maria near 0.7; drawn as it was, the disc was 0.40.
const moonExposure = 4.5;

/// Display-linear aureole at the limb of a full moon at night, in place of
/// the bake's flat halo (sky.frag adds 0.16 x cos^700, about 3 degrees wide,
/// which left the limb's surroundings at 0.24 on screen up to 2 radii out).
/// The surface pass falls it off as 1 / angle^2 with a faint skirt.
const moonGlow = 0.13;

/// The moon as a disc picture for per-pixel drawing, rendered at
/// [screenRadiusPx] (its reflected radius in physical pixels) times
/// [supersample], so the water samples it near 1:1. Asks [MoonBake.moon] for
/// the zoom tiles that size needs (they arrive later and notify, which
/// re-runs this). Null when the moon is below the horizon. The caller owns
/// the image.
Future<SkyMoon?> renderMoonDisc(MoonBake m, double azimuth, double screenRadiusPx,
    {double supersample = 1.5}) async {
  final rho = m.angularRadius;
  if (m.dir.y < -math.sin(rho)) {
    bakeDiag('moon not_drawn (below horizon)');
    return null;
  }
  final watch = Stopwatch()..start();
  final r = (screenRadiusPx * supersample).clamp(24.0, 1200.0).roundToDouble();
  final box = (2 * r / m.moon.fitFraction + 4).ceil();
  m.moon.setScreen(ui.Size(box.toDouble(), box.toDouble()), 1);
  final frame = MoonFrame(m.dir);
  final rec = ui.PictureRecorder();
  paintMoonDisc(ui.Canvas(rec),
      moon: m.moon,
      centre: ui.Offset(box / 2, box / 2),
      radius: r,
      sunAngle: frame.sunAngle(m.sunDir),
      illumination: m.illumination,
      dayness: m.dayness);
  final img = await _rasterise(rec, box, box);
  (double, double, double) w(Vec3 v) => worldToWater(v, azimuth);
  // sky.frag's halo scale (illumination, moon above the horizon, night).
  final glowScale =
      m.illumination * smoothstep(-0.05, 0.12, m.dir.y) * (1 - m.dayness).clamp(0.0, 1.0);
  bakeDiag('moon per_pixel alt=${(m.dir.altitude * radToDeg).toStringAsFixed(1)} '
      'screen_r=${screenRadiusPx.toStringAsFixed(1)} disc=${box}px '
      'tiles=${m.moon.drawTiles.length}/${m.moon.wantedTiles.length} ms=${watch.elapsedMilliseconds}');
  return SkyMoon(
    dir: w(frame.dir),
    right: w(frame.right),
    up: w(frame.up),
    angularRadius: rho,
    image: img,
    discFraction: r / box,
    exposure: moonExposure,
    bakedHalo: 0.16 * glowScale,
    glow: moonGlow * glowScale,
  );
}

/// [m] (rendered by [renderMoonDisc] for a camera facing [fromAz]) carried
/// [driftRad] of sidereal time about the pole at [latRad] and re-expressed
/// for a camera facing [toAz]. Same picture, so no re-render or upload of a
/// new image; the phase angle changes too slowly to matter between bakes.
SkyMoon driftedSkyMoon(SkyMoon m,
    {required double fromAz, required double toAz, required double latRad, required double driftRad}) {
  (double, double, double) turn((double, double, double) v) => worldToWater(
      driftedDirection(waterToWorld(v.$1, v.$2, v.$3, fromAz), latRad, driftRad), toAz);
  return SkyMoon(
    dir: turn(m.dir),
    right: turn(m.right),
    up: turn(m.up),
    angularRadius: m.angularRadius,
    image: m.image,
    discFraction: m.discFraction,
    exposure: m.exposure,
    bakedHalo: m.bakedHalo,
    glow: m.glow,
  );
}

/// Catalog stars at their equirect texels (centred, so a faint 1-texel
/// point is not split over four), with star_field's brightness and colour.
/// A bright star's disc is widened by 1/cos(elevation), as the equirect
/// stretches the sky there, so the water shows it round. Stars within a few
/// texels of the u seam are drawn on both sides, as the water wraps in u.
void paintEquirectStars(ui.Canvas c,
    {required ResolvedScene scene, required double azimuth, required int width, required int height}) {
  final w = width.toDouble();
  (ui.Offset, double)? at(Vec3 dir, double shift) {
    final (u, v) = equirectUv(dir, azimuth);
    final x = (u * width).floorToDouble() + 0.5 + shift;
    final y = (v * height).floorToDouble() + 0.5;
    if (shift != 0 && (x < -4 || x > w + 4)) return null;
    final stretch = 1 / math.max(math.cos(dir.altitude), 0.25);
    return (ui.Offset(x, y), stretch);
  }

  void paint(StarProjector project) => paintProjectedStars(c,
      scene: scene, time: 0, project: project, gain: starGain, discScale: starDiscScale);
  paint((d) => at(d, 0));
  // The two seam copies; anything not near an edge falls outside and is skipped.
  paint((d) => at(d, w));
  paint((d) => at(d, -w));
}

/// Positions in equirect pixels, texture coordinates in [cam] pixels.
class BakeMesh {
  BakeMesh(this.positions, this.texCoords, this.indices);
  final Float32List positions, texCoords;
  final Uint16List indices;
  ui.Vertices toVertices() => ui.Vertices.raw(ui.VertexMode.triangles, positions,
      textureCoordinates: texCoords, indices: indices);
}

/// 2-degree grid over every azimuth, zenith down to 4 degrees below the
/// horizon. Quads with a vertex the camera cannot project, or that lands
/// outside its picture, are dropped (those texels keep the fill colour).
BakeMesh? equirectMesh(SkyCamera cam, double azimuth, int ew, int eh) {
  const cols = 180, rows = 47;
  const vMax = 0.5 + 4 / 180;
  return _gridMesh(
    cols: cols,
    rows: rows,
    uv: (i, j) => (i / cols, vMax * j / rows),
    ew: ew,
    eh: eh,
    tex: (u, v) {
      final p = cam.project(equirectDir(u, v, azimuth));
      return p == null || !cam.contains(p) ? null : (p.dx, p.dy);
    },
  );
}

/// What stage 2 needs to know about the moon.
class MoonBake {
  const MoonBake({
    required this.moon,
    required this.dir,
    required this.sunDir,
    required this.illumination,
    required this.dayness,
    required this.angularRadius,
  });
  final MoonController moon;
  final Vec3 dir, sunDir;
  final double illumination, dayness, angularRadius;

  factory MoonBake.of(ResolvedScene s, MoonController moon, double angularRadius) => MoonBake(
        moon: moon,
        dir: s.moonDir,
        sunDir: s.sunDir,
        illumination: s.moonIllumination,
        dayness: s.dayness,
        angularRadius: angularRadius,
      );
}

/// Stage 2: [base] with the moon drawn in. Returns a clone of [base] when
/// the moon is below the horizon. [base] stays owned by the caller.
Future<ui.Image> composeSky(ui.Image base, double azimuth, MoonBake? m) async {
  if (m == null || m.dir.y < -math.sin(m.angularRadius)) {
    bakeDiag(m == null ? 'moon not_drawn (no moon image yet)' : 'moon not_drawn (below horizon)');
    return base.clone();
  }
  final watch = Stopwatch()..start();
  final ew = base.width, eh = base.height;
  final rho = m.angularRadius;
  final frame = MoonFrame(m.dir);
  final elev = m.dir.altitude;
  // Disc picture resolution: enough for the equirect's horizontal stretch.
  final pxPerRad = eh / math.pi;
  final r = (rho * pxPerRad * 1.5 / math.max(math.cos(elev), 0.3)).clamp(16.0, 1024.0);
  final box = (2 * r / m.moon.fitFraction + 4).ceil();
  final rec = ui.PictureRecorder();
  paintMoonDisc(ui.Canvas(rec),
      moon: m.moon,
      centre: ui.Offset(box / 2, box / 2),
      radius: r,
      sunAngle: frame.sunAngle(m.sunDir),
      illumination: m.illumination,
      dayness: m.dayness);
  final disc = await _rasterise(rec, box, box);

  final rec2 = ui.PictureRecorder();
  final c = ui.Canvas(rec2);
  c.drawImage(base, ui.Offset.zero, ui.Paint());
  final mesh = moonMesh(frame, rho, r, box.toDouble(), azimuth, ew, eh);
  if (mesh != null) {
    final v = mesh.toVertices();
    c.drawVertices(v, ui.BlendMode.srcOver, _imagePaint(disc));
    v.dispose();
  }
  final out = await _rasterise(rec2, ew, eh);
  disc.dispose();
  bakeDiag('moon drawn alt=${(elev * radToDeg).toStringAsFixed(1)} '
      'illum=${m.illumination.toStringAsFixed(2)} mesh=${mesh != null} ms=${watch.elapsedMilliseconds}');
  debugDumpSky(out, 'sky_composed');
  return out;
}

/// Grid over the moon's footprint in equirect u/v; texture coordinates are
/// gnomonic offsets in the disc picture ([box] square, disc radius [r] px).
BakeMesh? moonMesh(MoonFrame f, double rho, double r, double box, double azimuth, int ew, int eh) {
  final reach = rho * 1.3; // past the limb, into the picture's clear border
  final (uc, _) = equirectUv(f.dir, azimuth);
  final elev = f.dir.altitude;
  final e0 = math.max(elev - reach, -4 * degToRad);
  final e1 = math.min(elev + reach, math.pi / 2);
  final pole = elev + reach >= math.pi / 2 - 1e-3 || math.cos(elev) <= math.sin(reach);
  final du = pole ? 0.5 : math.asin(math.sin(reach) / math.cos(elev)) / (2 * math.pi);
  final u0 = pole ? 0.0 : uc - du, u1 = pole ? 1.0 : uc + du;
  final cols = pole ? 96 : 24;
  const rows = 24;
  final scale = r / math.tan(rho);
  return _gridMesh(
    cols: cols,
    rows: rows,
    uv: (i, j) => (u0 + (u1 - u0) * i / cols, 0.5 - (e1 - (e1 - e0) * j / rows) / math.pi),
    ew: ew,
    eh: eh,
    tex: (u, v) {
      final d = equirectDir(u, v, azimuth);
      final z = d.dot(f.dir);
      if (z < 0.2) return null;
      return (box / 2 + d.dot(f.right) / z * scale, box / 2 - d.dot(f.up) / z * scale);
    },
  );
}

BakeMesh? _gridMesh({
  required int cols,
  required int rows,
  required (double, double) Function(int i, int j) uv,
  required int ew,
  required int eh,
  required (double, double)? Function(double u, double v) tex,
}) {
  final stride = cols + 1;
  final n = stride * (rows + 1);
  final pos = Float32List(n * 2), tc = Float32List(n * 2);
  final ok = List<bool>.filled(n, false);
  for (var j = 0; j <= rows; j++) {
    for (var i = 0; i <= cols; i++) {
      final k = j * stride + i;
      final (u, v) = uv(i, j);
      pos[2 * k] = u * ew;
      pos[2 * k + 1] = v * eh;
      final t = tex(u, v);
      if (t == null) continue;
      ok[k] = true;
      tc[2 * k] = t.$1;
      tc[2 * k + 1] = t.$2;
    }
  }
  final idx = <int>[];
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final a = j * stride + i, b = a + 1, c = a + stride, d = c + 1;
      if (!(ok[a] && ok[b] && ok[c] && ok[d])) continue;
      idx.addAll([a, b, c, b, d, c]);
    }
  }
  if (idx.isEmpty) return null;
  return BakeMesh(pos, tc, Uint16List.fromList(idx));
}

/// Debug builds with `--dart-define=ILLUNIS_SKY_DUMP=true` only: writes
/// [img] as PNG to Directory.systemTemp (code_cache on Android), for
/// `adb exec-out run-as <pkg> cat code_cache/<name>.png`. Fire and forget;
/// never in profile or release.
const _dumpSky = bool.fromEnvironment('ILLUNIS_SKY_DUMP');
void debugDumpSky(ui.Image img, String name) {
  if (!kDebugMode || !_dumpSky) return;
  final copy = img.clone();
  () async {
    try {
      final png = await copy.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return;
      final f = File('${Directory.systemTemp.path}/$name.png');
      await f.writeAsBytes(png.buffer.asUint8List(), flush: true);
      bakeDiag('sky_dump ${f.path} ${img.width}x${img.height}');
    } catch (e) {
      bakeDiag('sky_dump_failed (${e.runtimeType})');
    } finally {
      copy.dispose();
    }
  }();
}

ui.Paint _imagePaint(ui.Image img) => ui.Paint()
  ..shader = ui.ImageShader(img, ui.TileMode.clamp, ui.TileMode.clamp, _identity,
      filterQuality: ui.FilterQuality.medium);

/// GPU-backed raster (Picture.toImage, not toImageSync): Flutter GPU's
/// Texture.fromImage needs that.
Future<ui.Image> _rasterise(ui.PictureRecorder rec, int w, int h) async {
  final pic = rec.endRecording();
  try {
    return await pic.toImage(w, h);
  } finally {
    pic.dispose();
  }
}
