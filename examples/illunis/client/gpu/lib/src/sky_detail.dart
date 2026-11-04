import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Sky features the surface pass draws per screen pixel instead of reading
/// them from the equirectangular bake, so they stay sharp at the display's
/// full density: catalog stars and planets as anti-aliased discs, and the
/// moon from a disc picture made at its on-screen size.
///
/// Directions are in the water frame the shader uses: x right, y up,
/// z forward (the bake's u = 0.5 + atan(x, z) / 2pi).
class SkyDetail {
  SkyDetail({required this.stars, this.moon, this.grain = 0});

  /// [starStride] floats per star: dir x, y, z (unit), alpha 0..1, disc
  /// radius in screen pixels, tint 0 (blue-white) .. 1 (orange).
  final Float32List stars;
  final SkyMoon? moon;

  /// Amplitude of the animated night grain the sky shader would have added
  /// at its own pixel size (the bake leaves it out).
  final double grain;

  static const starStride = 6;
  int get starCount => stars.length ~/ starStride;
}

/// The moon as a disc picture ([image], premultiplied, owned by the caller)
/// centred in a square, disc radius [discFraction] of its side.
class SkyMoon {
  const SkyMoon({
    required this.dir,
    required this.right,
    required this.up,
    required this.angularRadius,
    required this.image,
    required this.discFraction,
    this.exposure = 0,
    this.bakedHalo = 0,
    this.glow = 0,
  });

  /// Unit vectors: centre, horizontal right across the disc, and up toward
  /// the zenith (the picture's -y).
  final (double, double, double) dir, right, up;
  final double angularRadius;
  final ui.Image image;
  final double discFraction;

  /// Linear exposure of the disc picture before a soft shoulder (0 draws
  /// the picture as it is). The full moon is far brighter than the display
  /// can show, so it saturates toward white and keeps its maria in the
  /// shoulder.
  final double exposure;

  /// Amplitude of the halo the sky bake already holds (sky.frag's
  /// `0.16 * illum * moonUp * night * cos^700`, display-linear), which the
  /// surface pass removes so it can draw [glow] in its place. 0 keeps it.
  final double bakedHalo;

  /// Display-linear brightness of the aureole just outside the limb.
  final double glow;
}

/// A lookup grid for the stars over the upper hemisphere in the bake's
/// equirect u/v: [cols] x [rows] cells, [layers] stacked vertically, one
/// star per cell per layer. Every cell within [reach] radians of a star holds
/// it (brightest first, then the next layer), so the shader reads only the
/// cell under the pixel, once per layer.
///
/// Texel (RGBA32F): dir x, y, z, and alpha * 65536 + radius * 16 * 256 +
/// tint * 255, packed as exact integers (alpha and tint 8 bits, radius in
/// 1/16 px up to 15.9).
class StarGrid {
  StarGrid._(this.cols, this.rows, this.layers, this.texels, this.placed, this.dropped);

  final int cols, rows, layers;
  final Float32List texels;

  /// Star cells written, and cells a star lost because every layer was taken.
  final int placed, dropped;

  int get height => rows * layers;

  static double pack(double alpha, double radiusPx, double tint) =>
      (alpha.clamp(0.0, 1.0) * 255).roundToDouble() * 65536 +
      (radiusPx * 16).round().clamp(0, 255) * 256 +
      (tint.clamp(0.0, 1.0) * 255).roundToDouble();

  static (double, double, double) unpack(double p) {
    final a = (p / 65536).floor();
    final rest = p - a * 65536;
    final r = (rest / 256).floor();
    return (a / 255, r / 16, (rest - r * 256) / 255);
  }

  /// [pixelRad] is the angle of one screen pixel at the screen centre; a
  /// star reaches its radius plus 2 px of anti-aliasing, with [margin] for
  /// perspective and ripples.
  factory StarGrid.build(SkyDetail d, double pixelRad,
      {int cols = 1024, int rows = 256, int layers = 2, double margin = 1.6}) {
    final h = rows * layers;
    final t = Float32List(cols * h * 4);
    final n = d.starCount;
    final s = d.stars;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => s[b * 6 + 3].compareTo(s[a * 6 + 3]));
    final cellE = (math.pi / 2) / rows; // elevation per row
    final cellA = 2 * math.pi / cols; // azimuth per column
    var placed = 0, dropped = 0;
    for (final i in order) {
      final o = i * SkyDetail.starStride;
      final x = s[o], y = s[o + 1], z = s[o + 2];
      final alpha = s[o + 3], radius = s[o + 4];
      if (alpha <= 0 || y <= -0.01) continue;
      final e = math.asin(y.clamp(-1.0, 1.0));
      final a = math.atan2(x, z); // -pi..pi, u = 0.5 + a / 2pi
      final reach = (radius + 2) * pixelRad * margin;
      final packed = pack(alpha, radius, s[o + 5]);
      // Row r spans elevations [pi/2 - (r+1) cellE, pi/2 - r cellE].
      final r0 = ((math.pi / 2 - (e + reach)) / cellE).floor().clamp(0, rows - 1);
      final r1 = ((math.pi / 2 - (e - reach)) / cellE).floor().clamp(0, rows - 1);
      for (var r = r0; r <= r1; r++) {
        final top = math.pi / 2 - r * cellE;
        final eNear = math.min(top, e + reach).clamp(0.0, math.pi / 2);
        final cosE = math.cos(eNear);
        final dA = cosE <= math.sin(reach) ? math.pi : math.asin(math.sin(reach) / cosE);
        final uC = (a + math.pi) / cellA; // column coordinate of the star
        final c0 = (uC - dA / cellA).floor(), c1 = (uC + dA / cellA).floor();
        final span = c1 - c0 >= cols ? cols - 1 : c1 - c0;
        for (var k = 0; k <= span; k++) {
          final c = (c0 + k) % cols;
          var done = false;
          for (var l = 0; l < layers && !done; l++) {
            final ti = ((l * rows + r) * cols + c) * 4;
            if (t[ti + 3] != 0) continue;
            t[ti] = x;
            t[ti + 1] = y;
            t[ti + 2] = z;
            t[ti + 3] = packed;
            done = true;
            placed++;
          }
          if (!done) dropped++;
        }
      }
    }
    return StarGrid._(cols, rows, layers, t, placed, dropped);
  }
}

/// The sun drawn per screen pixel by the surface pass (milestone 1): an
/// anti-aliased, limb-darkened disc and its glare, composited in linear with
/// a soft shoulder so it saturates to white; it also lights the clouds.
/// Ripples spread the reflected disc into a glitter path on their own.
///
/// [dayFade] is the master switch for everything daytime (sun and clouds):
/// at 0 the shader skips the whole block and the frame is the night frame,
/// bit for bit. The app passes smoothstep(-12, -2, sun altitude in degrees).
class SkySun {
  const SkySun({
    required this.dir,
    required this.angularRadius,
    required this.colour,
    required this.intensity,
    required this.dayFade,
  });

  /// Unit vector in the water frame (x right, y up, z forward), as
  /// [SkyMoon.dir]. The disc shows down to 1 degree below the horizon.
  final (double, double, double) dir;

  /// Radians; 0.00465 for the real sun. 0 hides the disc and glare (clouds
  /// stay lit).
  final double angularRadius;

  /// Linear transmittance of the air toward the sun, 0..1 per channel
  /// (red-orange near the horizon). The disc's radiance is this colour.
  final (double, double, double) colour;

  /// Sun strength at its altitude, 0..1. Cloud lighting and the glare use
  /// colour x intensity.
  final double intensity;

  /// 0 night .. 1 day.
  final double dayFade;

  @override
  bool operator ==(Object other) =>
      other is SkySun &&
      other.dir == dir &&
      other.angularRadius == angularRadius &&
      other.colour == colour &&
      other.intensity == intensity &&
      other.dayFade == dayFade;

  @override
  int get hashCode => Object.hash(dir, angularRadius, colour, intensity, dayFade);
}

/// Night light on the cloud layer: the moon and the night sky's own glow
/// (the bake near the zenith). The cloud base is seen from below, so it is
/// darker than the sky behind it and hides the stars; a moon above the
/// horizon gives the thin edges a faint forward-scattered rim.
class CloudNight {
  const CloudNight({this.moonDir = (0, 1, 0), this.moonLight = 0, this.fade = 1});

  /// Unit direction to the moon in the water frame, as [SkyMoon.dir].
  final (double, double, double) moonDir;

  /// 0..1: lit fraction of the disc times its above-horizon ramp (sky.frag's
  /// moonUp). 0 leaves only the sky glow.
  final double moonLight;

  /// 0..1 weight of the night clouds; the app passes 1 - dayFade, so the
  /// layer stays at full strength through twilight. 0 turns them off.
  final double fade;

  @override
  bool operator ==(Object other) =>
      other is CloudNight && other.moonDir == moonDir && other.moonLight == moonLight && other.fade == fade;

  @override
  int get hashCode => Object.hash(moonDir, moonLight, fade);
}

/// Procedural moving clouds (milestone 2) on one plane above the water, lit
/// by [SkySun] by day and by [night] after dusk (without either, or at
/// dayFade 0 with no [night], they are off). Plus their shadow on the water
/// body (milestone 4, sun only).
///
/// Units: world units are the water's (camera height 1 = about 1 m; a sim
/// texel is ~1.7 mm), so [height] 1500 puts the cloud base 1.5 km up. A ray
/// meets the plane at rd.xz / rd.y * [height]; one repeat of the cloud
/// texture spans [tilePeriod] world units (6 km: puffs ~1 km across).
/// The renderer moves the clouds by [windVelocity] x [speed] x time, wrapped
/// on the tile period in Dart (no large time in the shader).
class SkyClouds {
  const SkyClouds({
    this.coverage = 0.45,
    this.density = 1.0,
    this.height = 1500,
    this.windVelocity = (0, 0),
    this.speed = 1.0,
    this.tier = 0,
    this.shadow = 0.6,
    this.night,
  });

  /// Moon and sky glow lighting the layer at night (null: day only).
  final CloudNight? night;

  /// Share of the sky covered, 0..1 (about; the noise is not uniform).
  final double coverage;

  /// Opacity scale, 0 (invisible) .. 1 (normal) .. 2 (thick).
  final double density;

  /// Cloud plane height in world units (metres at the default camera).
  final double height;

  /// Water-frame (x, z) in world units per second (m/s), the direction the
  /// clouds move toward.
  final (double, double) windVelocity;

  /// Time scale on the drift: 1 real time, larger for a livelier sky.
  final double speed;

  /// 0 (floor phones): base + detail layer, one light tap, half-strength
  /// shadow. 1 (flagship): two light taps, a cirrus layer, full shadow.
  final int tier;

  /// How much a cloud over the sun darkens the water body, 0..1.
  final double shadow;

  /// World units per repeat of the base layer.
  static const tilePeriod = 6000.0;

  /// Detail layer: frequency vs the base, and its drift vs the wind (so
  /// the shapes change as they move). Must match DETAIL_SCALE in the shader.
  static const detailScale = 3.7, detailDrift = 1.3;

  /// Cirrus layer (tier 1): frequency vs the base (CIRRUS_SCALE) and drift.
  static const cirrusScale = 1.6, cirrusDrift = 2.0;

  /// Texture uv offsets at [time] seconds, each wrapped to 0..1: base x, z,
  /// detail x, z, cirrus x, z. A texture feature appears at the plane point
  /// uv - offset, so the offsets run against the wind.
  List<double> layerOffsets(double time) {
    final dx = windVelocity.$1 * speed * time / tilePeriod;
    final dz = windVelocity.$2 * speed * time / tilePeriod;
    double w(double v) => (-v) % 1.0; // Dart's % is never negative
    const kd = detailScale * detailDrift, kc = cirrusScale * cirrusDrift;
    return [w(dx), w(dz), w(dx * kd), w(dz * kd), w(dx * kc), w(dz * kc)];
  }

  /// Cloud plates (CloudPlates): each plate is sampled twice, at two scales
  /// and rotations, each with its own phase and drift, so no single repeat
  /// period shows. Order A1, A2, B1, B2 (A = cumulus_02 spanning
  /// [tilePeriod] at scale 1, B = cumulus_06). A's two samples drift with
  /// the wind; B's at 0.6 of it (a higher-looking deck). Scale and angle
  /// must match PLATE_A1..PLATE_B2 in the shader.
  static const plateLayers = <PlateLayer>[
    PlateLayer(scale: 1.0, angle: 0.0, drift: 1.0, phase: (0.37, 0.21)),
    PlateLayer(scale: 1.37, angle: 2.2, drift: 1.0, phase: (1.13, 0.58)),
    PlateLayer(scale: 1.7, angle: 0.6, drift: 0.6, phase: (0.71, 1.43)),
    PlateLayer(scale: 2.3, angle: -1.1, drift: 0.6, phase: (1.62, 0.89)),
  ];

  /// Plate uv offsets at [time] seconds, x and z for A1, A2, B1, B2. Wrapped
  /// to 0..2, not 0..1: the plates are sampled with mirror addressing, which
  /// repeats every 2, so a wrap at 1 would flip the sky. Each drift is
  /// rotated into its sample's (rotated) uv frame, so it moves with the wind.
  List<double> plateOffsets(double time) {
    final dx = windVelocity.$1 * speed * time / tilePeriod;
    final dz = windVelocity.$2 * speed * time / tilePeriod;
    return [for (final l in plateLayers) ...l.offset(dx, dz)];
  }

  @override
  bool operator ==(Object other) =>
      other is SkyClouds &&
      other.coverage == coverage &&
      other.density == density &&
      other.height == height &&
      other.windVelocity == windVelocity &&
      other.speed == speed &&
      other.tier == tier &&
      other.shadow == shadow &&
      other.night == night;

  @override
  int get hashCode => Object.hash(coverage, density, height, windVelocity, speed, tier, shadow, night);
}

/// One plate sample: plane uv q is rotated by [angle] (radians), scaled by
/// [scale], then offset by [phase] minus the rotated wind drift.
class PlateLayer {
  const PlateLayer({required this.scale, required this.angle, required this.drift, required this.phase});

  final double scale, angle, drift;
  final (double, double) phase;

  /// uv offset for a drift of (dx, dz) plate periods, wrapped to 0..2.
  List<double> offset(double dx, double dz) {
    final c = math.cos(angle), s = math.sin(angle), k = scale * drift;
    final rx = (c * dx - s * dz) * k, rz = (s * dx + c * dz) * k;
    return [(phase.$1 - rx) % 2.0, (phase.$2 - rz) % 2.0];
  }

  /// The shader constant: vec4(scale, angle, 0.0, 0.0).
  String get glsl => 'vec4($scale, $angle, 0.0, 0.0)';
}
