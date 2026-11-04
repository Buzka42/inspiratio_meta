import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'celestial_math.dart';
import 'celestial_scene.dart';
import 'sky_painter.dart';
import 'sky_shader.dart';
import 'sky_state.dart';

/// The living sky. Give it a [SkyState]; it does the rest.
///
/// Ported from the original Illunis app without the instrument overlay
/// (paths, compass, glyphs). Eases every incoming value with its own time
/// constant so a step in state is a procession, not a cut, and eases the
/// camera toward whatever is worth looking at. Stops ticking when the app
/// is hidden or paused. Until the shader loads, or if it fails, the
/// painter draws a gradient fallback; catalog stars are drawn either way.
class SkyView extends StatefulWidget {
  const SkyView({
    super.key,
    required this.state,
    this.yawOffsetRad = 0,
    this.onScene,
    this.loadShader = true,
  });

  final SkyState state;

  /// Added to the tracked bearing.
  final double yawOffsetRad;

  /// Reports the eased, resolved scene each frame for chrome that wants it.
  final ValueChanged<ResolvedScene>? onScene;

  /// False keeps the gradient fallback (tests, or a device known to fail).
  final bool loadShader;

  @override
  State<SkyView> createState() => _SkyViewState();
}

class _SkyViewState extends State<SkyView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  late SkyState _display;
  late ResolvedScene _scene;
  double _azimuth = 0;
  double _yaw = 0;
  double _time = 0;
  Duration _last = Duration.zero;
  SkyShader? _shader;
  bool _reducedMotion = false;
  double _paintDebt = 0;

  // Time constants, seconds. The clock is followed closely; a vital eases
  // like weather; the camera turns like a head, not a servo.
  static const _tauClock = 0.22;
  static const _tauVitals = 1.4;
  static const _tauCamera = 1.6;
  static const _tauYaw = 0.35;

  @override
  void initState() {
    super.initState();
    _display = widget.state;
    _scene = CelestialScene.resolve(_display);
    _azimuth = _scene.trackAzimuthRad;
    _yaw = widget.yawOffsetRad;
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick)..start();
    if (widget.loadShader) {
      SkyShader.load().then((s) {
        if (mounted) {
          setState(() => _shader = s);
        } else {
          s?.dispose();
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is an unfocused window; the sky keeps moving. Only a
    // hidden or paused app stops paying for frames.
    final active =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (active && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!active && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    _time += dt;

    final target = widget.state;
    final kClock = 1 - math.exp(-dt / _tauClock);
    final kVitals = 1 - math.exp(-dt / _tauVitals);
    final clockPart = SkyState.lerp(_display, target, kClock);
    final vitalPart = SkyState.lerp(_display, target, kVitals);
    _display = SkyState(
      timeOfDay: clockPart.timeOfDay,
      dayOfYear: clockPart.dayOfYear,
      epochDays: clockPart.epochDays,
      latitudeDeg: clockPart.latitudeDeg,
      moonPhase: clockPart.moonPhase,
      solarNoon: clockPart.solarNoon,
      sleepScore: vitalPart.sleepScore,
      recovery: vitalPart.recovery,
      strain: vitalPart.strain,
      energyBalance: vitalPart.energyBalance,
    );
    // Decorative time does not change geometry.
    if (_scene.state != _display) _scene = CelestialScene.resolve(_display);

    final kCam = 1 - math.exp(-dt / _tauCamera);
    _azimuth = _easeAngle(_azimuth, _scene.trackAzimuthRad, kCam);
    final kYaw = 1 - math.exp(-dt / _tauYaw);
    _yaw += (widget.yawOffsetRad - _yaw) * kYaw;

    widget.onScene?.call(_scene);
    // Reduced motion: keep easing, but repaint at ~10 fps.
    if (_reducedMotion) {
      _paintDebt += dt;
      if (_paintDebt < 0.1) return;
      _paintDebt = 0;
    }
    setState(() {});
  }

  static double _easeAngle(double a, double b, double k) {
    var d = b - a;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    return wrapAngle(a + d * k);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    _reducedMotion = mq.disableAnimations;
    final az = wrapAngle(_azimuth + _yaw);
    return RepaintBoundary(
      child: CustomPaint(
        painter: SkyPainter(
          scene: _scene,
          azimuthRad: az,
          shader: _shader,
          time: mq.disableAnimations ? 0 : _time,
          devicePixelRatio: mq.devicePixelRatio,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
