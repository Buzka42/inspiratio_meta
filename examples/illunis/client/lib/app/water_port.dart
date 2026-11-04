import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

import '../voice/voice_session.dart';
import '../widgets/water_pass.dart';
import 'app_controller.dart';
import 'illunis_root.dart';
import 'reflection_geometry.dart';

/// Default water stillness: near mirror calm, so most of the time nothing
/// visibly moves (0 = mirror calm, 1 = rough).
const defaultStillness = 0.04;

/// What the Reflection water needs each build. Same for both options.
class WaterInputs {
  const WaterInputs({
    this.sky,
    this.walker = const Offset(0.5, 0.8),
    this.loudness = 0,
    this.vignette = 1,
    this.stillness = defaultStillness,
    this.detail,
    this.sun,
    this.clouds,
    this.ripples,
  });

  final ui.Image? sky; // equirectangular 2:1
  final Offset walker; // screen, normalised 0..1
  final double loudness; // 0..1
  final double vignette; // 0..1
  final double stillness; // 0 mirror calm .. 1 rough

  /// Stars and moon for a port that draws them per pixel
  /// ([WaterPort.drawsSkyDetail]); [sky] then leaves them out.
  final SkyDetail? detail;

  /// Day sky drawn per pixel by a [WaterPort.drawsSkyDetail] port (the bake
  /// then leaves the sun disc out). Option A uses [sun] only for its glint
  /// and ignores [clouds].
  final SkySun? sun;
  final SkyClouds? clouds;

  /// Voice ripples fed by someone else (option B's fallback). Null: the port
  /// feeds its own from the voice state.
  final RippleSources? ripples;
}

/// Strength of a voice ripple for [level] 0..1 (the mic level; 0 when none
/// is reported, which gives the fixed strength 0.6).
double voiceRippleStrength(double level) => 0.6 + 0.4 * level.clamp(0.0, 1.0);

/// Starts a ripple on [sources] each time [controller]'s voice state turns
/// to listening, through the controller's existing listener. [level] reads
/// the current mic level. Call [dispose] to unsubscribe.
class VoiceRippleFeed {
  VoiceRippleFeed(this.controller, this.sources, {double Function()? level})
      : _level = level ?? (() => 0),
        _last = controller.voice {
    controller.addListener(_changed);
  }

  final AppController controller;
  final RippleSources sources;
  final double Function() _level;
  VoiceState _last;

  void _changed() {
    final v = controller.voice;
    if (v == VoiceState.listening && _last != VoiceState.listening) {
      sources.start(voiceRippleStrength(_level()));
    }
    _last = v;
  }

  void dispose() => controller.removeListener(_changed);
}

/// Feeds [sources] (or its own when null) from the voice state of the
/// [IllunisRoot] above it, then builds [builder] with them.
class _VoiceRipples extends StatefulWidget {
  const _VoiceRipples({this.sources, required this.level, required this.builder});
  final RippleSources? sources;
  final double level;
  final Widget Function(RippleSources sources) builder;

  @override
  State<_VoiceRipples> createState() => _VoiceRipplesState();
}

class _VoiceRipplesState extends State<_VoiceRipples> {
  late final RippleSources _own = widget.sources ?? RippleSources();
  VoiceRippleFeed? _feed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.findAncestorWidgetOfExactType<IllunisRoot>()?.controller;
    if (c == _feed?.controller) return;
    _feed?.dispose();
    _feed = c == null ? null : VoiceRippleFeed(c, _own, level: () => widget.level);
  }

  @override
  void dispose() {
    _feed?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_own);
}

/// Option B's drops plus one footstep-sized drop at the sim cell under the
/// screen centre for each new voice ripple. [aspect] is the screen's
/// width / height (the sim domain depends on it).
class VoiceDropScheduler extends DropScheduler {
  VoiceDropScheduler(this.sources, this.camera, this.aspect);

  final RippleSources sources;
  final WaterCamera camera;
  final double Function() aspect;
  int _seen = 0;

  /// Footstep drop size (world units) and depth at strength 1.
  static const radius = 0.05, depth = 0.8;

  @override
  List<Drop> next(double dt, Offset? walkerCell, double loudness, int w, int h, double cellWorld) {
    final base = super.next(dt, walkerCell, loudness, w, h, cellWorld);
    final fresh = sources.since(_seen);
    if (fresh.isEmpty) return base;
    _seen = fresh.last.id;
    final a = aspect();
    final hit = camera.planeHit(const Offset(0.5, 0.5), a);
    if (hit == null) return base;
    final c = worldToCell(hit, camera.simDomain(a), w, h);
    final out = [
      for (final r in fresh) Drop(c.dx, c.dy, radius / cellWorld, -depth * r.strength),
      ...base,
    ];
    return out.length > maxDropsPerStep ? out.sublist(0, maxDropsPerStep) : out;
  }
}

/// Draws the Reflection-mode water.
abstract interface class WaterPort {
  Widget build(WaterInputs inputs);

  /// The camera the water currently draws with, for placing the moon's
  /// reflection (hit tests). Changes when option B falls back to A.
  ValueListenable<ReflectionOptics> get optics;

  /// True when the port draws stars and the moon per screen pixel from
  /// [WaterInputs.detail], so the sky bake should leave them out. May turn
  /// false later (option B fell back to A); [optics] notifies then.
  bool get drawsSkyDetail;
}

class _Fixed<T> implements ValueListenable<T> {
  const _Fixed(this.value);
  @override
  final T value;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _Optics extends ValueNotifier<ReflectionOptics> {
  _Optics() : super(ReflectionOptics.analytic);
  void ping() => notifyListeners();
}

String? _lastDiag;

/// Debug-only, and only when the path changes (build runs every frame).
void _waterDiag(String m) {
  if (!kDebugMode || m == _lastDiag) return;
  _lastDiag = m;
  debugPrint('illunis_diag: $m');
}

/// Option A's default loader, logging whether water.frag compiled.
Future<ui.FragmentProgram> _loggedWaterProgram() =>
    ui.FragmentProgram.fromAsset('shaders/water.frag').then((p) {
      if (kDebugMode) debugPrint('illunis_diag: water_a shader loaded');
      return p;
    }, onError: (Object e, StackTrace st) {
      if (kDebugMode) debugPrint('illunis_diag: water_a shader fallback (${e.runtimeType}: $e)');
      return Future<ui.FragmentProgram>.error(e, st);
    });

/// Option A: the single-pass analytic shader (shaders/water.frag).
class AnalyticWaterPort implements WaterPort {
  const AnalyticWaterPort({this.programLoader});
  final Future<ui.FragmentProgram> Function()? programLoader;

  @override
  ValueListenable<ReflectionOptics> get optics => const _Fixed(ReflectionOptics.analytic);

  @override
  bool get drawsSkyDetail => false;

  @override
  Widget build(WaterInputs i) {
    _waterDiag(i.sky == null
        ? 'water option_a gradient (sky not baked yet)'
        : 'water option_a with baked sky');
    final loader = programLoader ?? (kDebugMode ? _loggedWaterProgram : null);
    Widget pass(RippleSources r) => loader == null
        ? WaterPass(
            sky: i.sky, walker: i.walker, loudness: i.loudness, vignette: i.vignette,
            stillness: i.stillness, sun: i.sun, ripples: r)
        : WaterPass(
            sky: i.sky, walker: i.walker, loudness: i.loudness, vignette: i.vignette,
            stillness: i.stillness, sun: i.sun, ripples: r, programLoader: loader);
    final fed = i.ripples;
    return fed != null ? pass(fed) : _VoiceRipples(level: i.loudness, builder: pass);
  }
}

/// Option B: GPU heightfield simulation on Flutter GPU (client/gpu). Falls
/// back to option A while loading and whenever Flutter GPU is unavailable.
///
/// [optics] reads option A until the GPU renderer has started, then option
/// B; it returns to A when the renderer fails to start. (A failure in a later
/// frame also shows option A but is not reported here: GpuWater only logs it.)
class GpuWaterPort implements WaterPort {
  GpuWaterPort({this.fallback = const AnalyticWaterPort(), GpuWaterFactory? factory}) {
    _factory = factory ??
        ((sky, cam) => GpuWaterRenderer.create(
            sky: sky, camera: cam, drops: VoiceDropScheduler(ripples, cam, () => _aspect)));
  }
  final AnalyticWaterPort fallback;
  late final GpuWaterFactory _factory;

  /// Voice ripples for both the simulation (as drops) and the fallback.
  final ripples = RippleSources();
  double _aspect = 9 / 16;
  final _optics = _Optics();
  bool _failed = false;

  @override
  ValueListenable<ReflectionOptics> get optics => _optics;

  @override
  bool get drawsSkyDetail => !_failed;

  void _fellBack() {
    if (_failed) return;
    _failed = true;
    _optics.value = ReflectionOptics.analytic;
    // The analytic value may already be set (start failure); still tell the
    // listeners that the sky must be re-baked with its stars and moon.
    _optics.ping();
  }

  Future<GpuWaterRenderer> _start(ui.Image sky, WaterCamera cam) => _factory(sky, cam).then(
        (r) {
          _waterDiag('water gpu started ${sky.width}x${sky.height}');
          _optics.value = ReflectionOptics(cam.pitch, fovScale: cam.fovScale);
          return r;
        },
        onError: (Object e, StackTrace st) {
          _waterDiag('water gpu fallback_to_a (${e.runtimeType}: $e)');
          _fellBack();
          return Future<GpuWaterRenderer>.error(e, st);
        },
      );

  @override
  Widget build(WaterInputs i) => _VoiceRipples(
      sources: ripples,
      level: i.loudness,
      builder: (_) => LayoutBuilder(builder: (_, box) {
            if (box.hasBoundedWidth && box.hasBoundedHeight && box.maxHeight > 0) {
              _aspect = box.maxWidth / box.maxHeight;
            }
            return _gpu(i);
          }));

  Widget _gpu(WaterInputs i) => GpuWater(
        sky: i.sky,
        walker: i.walker,
        loudness: i.loudness,
        vignette: i.vignette,
        stillness: i.stillness,
        factory: _start,
        detail: i.detail,
        sun: i.sun,
        clouds: i.clouds,
        onFailed: _fellBack,
        fallback: (_) => fallback.build(WaterInputs(
            sky: i.sky, walker: i.walker, loudness: i.loudness, vignette: i.vignette,
            stillness: i.stillness, sun: i.sun, ripples: ripples)),
      );
}

/// The Reflection water is the high-resolution GPU view (option B), the only option. It falls back to the
/// plain water on any failure (GpuWaterPort), so a device that cannot run it still shows the sky.
WaterPort waterPort() {
  if (kDebugMode) debugPrint('illunis_diag: water choice=gpu');
  return GpuWaterPort();
}
