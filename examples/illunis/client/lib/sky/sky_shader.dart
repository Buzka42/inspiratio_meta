import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'celestial_scene.dart';
import 'sky_camera.dart';

/// Loads `shaders/sky.frag` once and knows the order of its uniforms.
///
/// Ported from the original Illunis app without the weather pass. The index
/// layout below must match the uniform table at the top of sky.frag.
class SkyShader {
  SkyShader._(this._program);

  final ui.FragmentProgram _program;
  ui.FragmentShader? _skyInstance;

  static const String assetKey = 'shaders/sky.frag';

  /// Number of floats [write] sets; equals the last index in sky.frag + 1.
  static const int floatCount = 44;

  static Future<ui.FragmentProgram>? _loading;
  static bool _logged = false;

  static void _diag(String m) {
    if (kDebugMode && !_logged) {
      _logged = true;
      debugPrint('illunis_diag: $m');
    }
  }

  /// Resolves once per process; a failure is remembered as null so the
  /// painter falls back instead of retrying every frame.
  static Future<SkyShader?> load() {
    _loading ??= ui.FragmentProgram.fromAsset(assetKey);
    return _loading!.then<SkyShader?>(
      (p) {
        _diag('sky_shader loaded');
        return SkyShader._(p);
      },
      onError: (Object e, StackTrace st) {
        _diag('sky_shader fallback (${e.runtimeType}: $e)');
        debugPrint('sky_shader_unavailable');
        return null;
      },
    );
  }

  ui.FragmentShader newShader() => _skyInstance ??= _program.fragmentShader();

  void dispose() {
    _skyInstance?.dispose();
    _skyInstance = null;
  }

  /// Angular radii, radians. The sun is drawn near true size; the moon is
  /// enlarged about 3x so its surface reads on a phone — the one stylisation.
  static const double sunAngularRadius = 0.00465;
  static const double moonAngularRadius = 0.014;

  /// The uniform values in sky.frag index order. Pure, so tests can check
  /// the layout without a GPU.
  static List<double> uniforms({
    required ResolvedScene scene,
    required SkyCamera camera,
    required double time,
    double pixelScale = 1.0,
  }) {
    final s = scene;
    return <double>[
      camera.size.width, // 0  uSize.x
      camera.size.height, // 1  uSize.y
      camera.principal.dx, // 2  uPrincipal.x
      camera.principal.dy, // 3  uPrincipal.y
      camera.focal, // 4  uFocal
      camera.azimuthRad, // 5  uAzimuth
      s.sunDir.x, // 6  uSunDir
      s.sunDir.y, // 7
      s.sunDir.z, // 8
      s.moonDir.x, // 9  uMoonDir
      s.moonDir.y, // 10
      s.moonDir.z, // 11
      s.siderealRad, // 12 uSidereal
      s.latitudeRad, // 13 uLatitude
      s.turbidity, // 14 uTurbidity
      s.mieScale, // 15 uMie
      s.exposure, // 16 uExposure
      s.stillness, // 17 uStillness
      time, // 18 uTime
      moonAngularRadius, // 19 uMoonRadius
      sunAngularRadius, // 20 uSunRadius
      s.moonIllumination, // 21 uMoonIllum
      s.dayness, // 22 uDayness
      // 23-42 uPlanet0..4: dir.xyz, brightness x visibility.
      for (final p in s.planets) ...[
        p.dir.x,
        p.dir.y,
        p.dir.z,
        p.brightness * p.visibility,
      ],
      pixelScale, // 43 uPixelScale
    ];
  }

  static void write(
    ui.FragmentShader shader, {
    required ResolvedScene scene,
    required SkyCamera camera,
    required double time,
    double pixelScale = 1.0,
  }) {
    final values = uniforms(
      scene: scene,
      camera: camera,
      time: time,
      pixelScale: pixelScale,
    );
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
  }
}
