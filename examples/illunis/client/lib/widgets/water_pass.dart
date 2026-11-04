import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:illunis_gpu/illunis_gpu.dart' show SkySun;

/// Reflection mode: the whole screen is one water surface reflecting [sky].
/// Runs shaders/water.frag; if the shader or the image is unavailable it
/// paints the reflected band of the image (or a gradient) instead.
///
/// [sky] is an equirectangular (2:1) image: u from azimuth, v from
/// elevation, zenith at the top row and the horizon at mid-height.
class WaterPass extends StatefulWidget {
  const WaterPass({
    super.key,
    this.sky,
    this.walker = const Offset(0.5, 0.8),
    this.loudness = 0,
    this.vignette = 1.0,
    this.stillness = 1.0,
    this.sun,
    this.ripples,
    this.programLoader = _defaultLoader,
  });

  final ui.Image? sky;
  final Offset walker; // screen position, normalised 0..1
  final double loudness; // 0..1
  final double vignette; // edge darkening 0..1, 0 = off
  final double stillness; // 0 mirror calm .. 1 rough (the look before this value)

  /// The sun for the glint (water frame). Null, below the horizon or with a
  /// zero [SkySun.angularRadius] draws no glint.
  final SkySun? sun;

  /// Voice ripple rings, sampled every frame. Null draws none.
  final RippleSources? ripples;
  final Future<ui.FragmentProgram> Function() programLoader;

  static Future<ui.FragmentProgram> _defaultLoader() =>
      ui.FragmentProgram.fromAsset('shaders/water.frag');

  @override
  State<WaterPass> createState() => _WaterPassState();
}

class _WaterPassState extends State<WaterPass> with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController(vsync: this, duration: const Duration(hours: 1))..repeat();
  ui.FragmentProgram? _program;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.programLoader().then((p) {
      if (mounted) setState(() => _program = p);
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _program;
    if (_failed || p == null || widget.sky == null) {
      return CustomPaint(
        key: const ValueKey('water-fallback'),
        painter: _PlainPainter(widget.sky),
        size: Size.infinite,
      );
    }
    // Full-size CustomPaint: the rect is rasterised at the device's physical
    // resolution, so the shader runs once per physical pixel.
    return AnimatedBuilder(
      animation: _t,
      builder: (_, _) => CustomPaint(
        key: const ValueKey('water-shader'),
        painter: _WaterPainter(p, widget.sky!, _t.value * 3600, widget.walker,
            widget.loudness, widget.vignette, widget.stillness, widget.sun,
            widget.ripples?.uniforms() ?? RippleSources.silent),
        size: Size.infinite,
      ),
    );
  }
}

class _PlainPainter extends CustomPainter {
  _PlainPainter(this.img);
  final ui.Image? img;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final i = img;
    if (i == null) {
      canvas.drawRect(
          r,
          Paint()
            ..shader = const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF223A5E), Color(0xFF0B1630)])
                .createShader(r));
      return;
    }
    // Roughly the band the calm water reflects: centre azimuths, elevations
    // ~14..76 degrees, flipped so low sky sits at the top of the screen.
    final src = Rect.fromLTRB(i.width * 0.44, i.height * 0.08, i.width * 0.56, i.height * 0.42);
    canvas.save();
    canvas.translate(0, size.height);
    canvas.scale(1, -1);
    canvas.drawImageRect(i, src, r, Paint()..filterQuality = FilterQuality.low);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlainPainter o) => o.img != img;
}

class _WaterPainter extends CustomPainter {
  _WaterPainter(this.program, this.sky, this.time, this.walker, this.loud, this.vignette,
      this.stillness, this.sun, this.ripples);
  final ui.FragmentProgram program;
  final SkySun? sun;
  final List<double> ripples; // slots 14-21
  final ui.Image sky;
  final double time, loud, vignette, stillness;
  final Offset walker;

  // Float slots must match the uniform order documented in water.frag.
  @override
  void paint(Canvas canvas, Size size) {
    final s = program.fragmentShader()
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time)
      ..setFloat(3, walker.dx)
      ..setFloat(4, walker.dy)
      ..setFloat(5, loud.clamp(0.0, 1.0))
      ..setFloat(6, vignette.clamp(0.0, 1.0))
      ..setFloat(7, stillness.clamp(0.0, 1.0));
    final (dir, light) = glintUniforms(sun);
    for (var i = 0; i < 3; i++) {
      s
        ..setFloat(8 + i, dir[i])
        ..setFloat(11 + i, light[i]);
    }
    for (var i = 0; i < ripples.length; i++) {
      s.setFloat(14 + i, ripples[i]);
    }
    // Bilinear: sub-texel ripple offsets stay smooth instead of stepping.
    s.setImageSampler(0, sky, filterQuality: FilterQuality.low);
    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(_WaterPainter o) => true;
}

/// One voice ripple: started at [start] seconds on its [RippleSources]
/// clock with [strength] 0..1. [id] counts up from 1 per source set.
class Ripple {
  const Ripple(this.id, this.start, this.strength);
  final int id;
  final double start, strength;
}

/// Up to [maxRipples] voice ripple rings spreading from the water's centre.
/// Each lives [life] seconds; its amplitude is strength x [envelope](age).
/// Starting one more than [maxRipples] replaces the oldest.
class RippleSources {
  RippleSources({double Function()? clock}) : _clock = clock ?? _monotonic;

  static const maxRipples = 4;
  static const life = 2.5;

  /// Uniform slots 14-21 with no ripple.
  static const silent = <double>[0, 0, 0, 0, 0, 0, 0, 0];

  static final _watch = Stopwatch()..start();
  static double _monotonic() => _watch.elapsedMicroseconds / 1e6;

  final double Function() _clock;
  final _live = <Ripple>[];
  int _lastId = 0;

  double get now => _clock();

  /// 1 at the start, easing to 0 at [life]; 0 outside 0..life.
  static double envelope(double age) {
    if (age < 0 || age >= life) return 0;
    final f = 1 - age / life;
    return f * f;
  }

  void _prune(double t) => _live.removeWhere((r) => t - r.start >= life);

  /// Live ripples, oldest first.
  List<Ripple> get live {
    _prune(now);
    return List.unmodifiable(_live);
  }

  /// Ripples started after the one with [id] (0: all live), oldest first.
  List<Ripple> since(int id) => [for (final r in live) if (r.id > id) r];

  Ripple start(double strength) {
    final t = now;
    _prune(t);
    if (_live.length >= maxRipples) _live.removeAt(0);
    final r = Ripple(++_lastId, t, strength.clamp(0.0, 1.0).toDouble());
    _live.add(r);
    return r;
  }

  /// Float slots 14-21 of water.frag: (age, amplitude) per source.
  List<double> uniforms() {
    final t = now;
    _prune(t);
    final out = List<double>.of(silent);
    for (var i = 0; i < _live.length; i++) {
      final age = t - _live[i].start;
      out[2 * i] = age;
      out[2 * i + 1] = _live[i].strength * envelope(age);
    }
    return out;
  }
}

/// Float slots 8-10 (sun direction, water frame) and 11-13 (glint light,
/// colour x intensity) for [sun]; light is zero when there is no glint.
(List<double>, List<double>) glintUniforms(SkySun? sun) {
  const none = ([0.0, -1.0, 0.0], [0.0, 0.0, 0.0]);
  if (sun == null || sun.angularRadius <= 0) return none;
  final (x, y, z) = sun.dir;
  final len = math.sqrt(x * x + y * y + z * z);
  if (len == 0 || y <= 0) return none;
  final k = sun.intensity.clamp(0.0, 1.0);
  final (r, g, b) = sun.colour;
  return (
    [x / len, y / len, z / len],
    [r.clamp(0.0, 1.0) * k, g.clamp(0.0, 1.0) * k, b.clamp(0.0, 1.0) * k],
  );
}

/// Procedural equirectangular night sky ([width] x [width]/2): an elevation
/// gradient with a faint horizon glow, a seeded star field and a soft moon
/// disc ahead of the camera. Synthetic placeholder only.
///
/// Intended source: the owner's Gemini plain-sky images (prompts 1-25 in
/// docs/SKY.md). Those prompts ask for portrait 9:16 photos,
/// not equirectangular panoramas, so a photo must be reprojected (or the
/// prompts reworded for a 2:1 equirectangular sky) before it is passed here.
Future<ui.Image> proceduralEquirectSky({int width = 4096, int seed = 7}) {
  final w = width.toDouble(), h = w / 2;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final full = Rect.fromLTWH(0, 0, w, h);
  // v 0 = zenith, 0.5 = horizon, 1 = nadir.
  c.drawRect(
      full,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF040A1C), Color(0xFF0B1A3E), Color(0xFF1C2E5C),
            Color(0xFF4A4F7E), Color(0xFF8A7088), Color(0xFF0A0E1A),
          ],
          stops: [0.0, 0.22, 0.38, 0.46, 0.5, 0.56],
        ).createShader(full));

  double vOf(double elev) => 0.5 - elev / math.pi;
  // Draws at (u, elev) stretched horizontally by 1/cos(elev), so the shape
  // stays round once the equirectangular map is projected back.
  void atSky(double u, double elev, void Function() draw) {
    c.save();
    c.translate(u * w, vOf(elev) * h);
    c.scale(1 / math.max(math.cos(elev), 0.15), 1);
    draw();
    c.restore();
  }

  final rnd = math.Random(seed);
  final star = Paint();
  final n = (width * 0.9).round();
  for (var i = 0; i < n; i++) {
    final elev = math.asin(0.05 + 0.92 * rnd.nextDouble()); // uniform on the dome
    final u = rnd.nextDouble();
    final mag = math.pow(rnd.nextDouble(), 3).toDouble();  // most stars faint
    final haze = (elev / 0.35).clamp(0.0, 1.0);             // dimmer near horizon
    final rad = (0.5 + 1.6 * mag) * w / 4096;
    final warm = rnd.nextDouble();
    star.color = Color.fromARGB((255 * (0.25 + 0.75 * mag) * haze).round(),
        235 + (20 * warm).round(), 235, 255 - (30 * warm).round());
    atSky(u, elev, () => c.drawCircle(Offset.zero, rad, star));
  }

  // Moon ahead of the camera (u 0.5), 32 degrees up: glow, then a soft disc.
  final moonR = w * 0.0045;
  atSky(0.5, 32 * math.pi / 180, () {
    c.drawCircle(
        Offset.zero,
        moonR * 9,
        Paint()
          ..shader = ui.Gradient.radial(Offset.zero, moonR * 9,
              const [Color(0x55C8D2F0), Color(0x00C8D2F0)]));
    c.drawCircle(
        Offset.zero,
        moonR,
        Paint()
          ..color = const Color(0xFFF4EEDC)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, moonR * 0.12));
  });
  return rec.endRecording().toImage(width, width ~/ 2);
}
