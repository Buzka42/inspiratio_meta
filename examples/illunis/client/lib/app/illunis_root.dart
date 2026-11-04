import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:illunis_gpu/illunis_gpu.dart' show SkyDetail, SkyMoon;

import '../breath/breath_view.dart';
import '../breath/breath_wiring.dart';
import '../captions/caption_style.dart';
import '../captions/caption_view.dart';
import '../core/mode_controller.dart';
import '../logs/views/log_views.dart';
import '../sky/celestial_scene.dart';
import '../sky/sky_shader.dart';
import '../sky/sky_state.dart';
import '../sky/star_field.dart' show driftedDirection, siderealDriftRad;
import '../sky/wind.dart';
import '../ui/sky_light.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../widgets/chat_composer.dart';
import '../widgets/glass/glass_sheet.dart';
import 'app_controller.dart';
import 'chat_thread.dart';
import 'classic_view.dart';
import 'day_sky.dart';
import 'digest_ticker.dart';
import 'moon_focus.dart';
import 'reflection_geometry.dart';
import 'sky_bake.dart';
import 'sky_debug_override.dart';
import 'stillness_debug.dart';
import 'view_offer.dart';
import 'view_requests.dart' show ViewKind;
import 'water_port.dart';

/// Fallback location until the device location is read. Greenwich
/// Observatory; not the user's position.
const greenwichDefaultLat = 51.4769;
const greenwichDefaultLng = 0.0;

/// The one main view. Reflection (the default): the whole screen is water
/// reflecting the real sky, which is baked from client/lib/sky with the
/// textured moon drawn into it. Classic: the same sky drawn directly, no
/// water. Captions centred on the sky, with the fog dissolve when fog is on
/// and static (a plain fade) when it is off (docs/SKY.md section 7). With a
/// [IllunisRoot.chat] thread, the text chat composer sits at the bottom
/// whatever the fog setting is, and a view opened through [ViewHost] (only
/// after a yes) covers the sky until closed. Pinch or drag on the
/// moon (or its reflection) zooms or turns it; elsewhere a gesture does
/// nothing. Debug builds only: a three-finger long press opens a stillness
/// slider.
class IllunisRoot extends StatefulWidget {
  const IllunisRoot({
    super.key,
    required this.controller,
    this.lat = greenwichDefaultLat,
    this.lng = greenwichDefaultLng,
    this.waterProgramLoader,
    this.water,
    this.focus,
    this.now,
    this.ticker,
    this.stillness,
    this.bakeConfig = const SkyBakeConfig(),
    this.loadSkyShader = true,
    this.clockPeriod = const Duration(minutes: 1),
    this.skyOverride,
    this.sun,
    this.sunPeriod = const Duration(seconds: 1),
    this.wind,
    this.skyTier,
    this.clock,
    this.drift,
    this.detailPeriod = const Duration(seconds: 4),
    this.chat,
    this.views,
    this.logs,
    this.onSubmit,
    this.breath,
    this.probeSky,
    this.probePeriod = const Duration(seconds: 2),
  });

  /// Looks at the drawn sky every [probePeriod] so the glass can be as clear
  /// as contrast allows ([SkyProbe]). Null follows [loadSkyShader] (off in
  /// tests, which draw no real sky).
  final bool? probeSky;
  final Duration probePeriod;

  /// Library, onboarding store and cue voice for the breathwork view. Null
  /// makes one with the bundled library and screen-only cues.
  final BreathDeps? breath;

  /// The typed chat thread. Null shows no composer (voice-only builds).
  final ChatThread? chat;

  /// Views opened after a yes ([ViewHost.open]). Null shows none.
  final ViewHost? views;

  /// Store, server and device signals for the log views. Null shows the
  /// placeholder for a log view.
  final LogViews? logs;

  /// A typed message or a tapped Yes / No. Null uses [submitTypedTurn].
  final void Function(String text)? onSubmit;

  final AppController controller;
  final double lat, lng;

  /// Overrides the option A water shader loader (tests).
  final Future<ui.FragmentProgram> Function()? waterProgramLoader;

  /// Reflection water (option A or B). Null keeps option A with
  /// [waterProgramLoader].
  final WaterPort? water;

  /// Moon zoom state shared with the voice intents. Null makes one with no
  /// moon imagery (the sky shader's moon only).
  final MoonFocus? focus;

  /// Fixed clock (tests). Null follows the wall clock every [clockPeriod].
  final DateTime? now;

  /// Digest scheduler owned by the app; cancelled when this widget goes away.
  final DigestTicker? ticker;

  /// Water stillness, 0 mirror calm .. 1 rough. Null uses [defaultStillness].
  final ValueNotifier<double>? stillness;

  final SkyBakeConfig bakeConfig;

  /// False keeps the sky's gradient fallback (tests).
  final bool loadSkyShader;
  final Duration clockPeriod;

  /// Fixed sky time and place. Null uses [debugSkyOverride] (the
  /// ILLUNIS_SKY_* defines, debug builds only; empty in release).
  final SkyOverride? skyOverride;

  /// The day sun the water draws per pixel, in the frame of the current
  /// bake. Updated every [sunPeriod] (the sun moves about its own diameter a
  /// minute) without a re-bake; still when the time is fixed ([now] or
  /// ILLUNIS_SKY_TIME). Null makes one owned by this widget.
  final ValueNotifier<DaySun?>? sun;
  final Duration sunPeriod;

  /// Wind the clouds drift with. Null makes [WindSource.standard] (4 m/s
  /// from the west, or ILLUNIS_SKY_WIND in debug builds).
  final WindSource? wind;

  /// Cloud quality tier (0 floor, 1 flagship). Null uses ILLUNIS_SKY_TIER
  /// (debug builds only), else 0.
  final int? skyTier;

  /// Wall clock (tests inject one). Null is DateTime.now. Drives the scene
  /// time unless [now] or ILLUNIS_SKY_TIME fixes it, and the drift.
  final DateTime Function()? clock;

  /// Sidereal angle (radians) the sky has turned since the scene was last
  /// resolved, updated every [sunPeriod] (about 0.004 degrees a second) so
  /// the stars and moon move smoothly between the once-a-minute resolves;
  /// 0 when the time is fixed. Null makes one owned by this widget.
  final ValueNotifier<double>? drift;

  /// How often Reflection's per-pixel stars and moon ([SkyDetail]) are
  /// rebuilt for the drift. A few seconds keeps the step under a pixel and
  /// the moon texture upload rare.
  final Duration detailPeriod;

  @override
  State<IllunisRoot> createState() => _IllunisRootState();
}

class _IllunisRootState extends State<IllunisRoot> {
  late final MoonFocus _focus = widget.focus ?? MoonFocus();
  late final ValueNotifier<double> _still =
      widget.stillness ?? ValueNotifier(defaultStillness);
  late final WaterPort _water =
      widget.water ?? AnalyticWaterPort(programLoader: widget.waterProgramLoader);

  late ResolvedScene _scene;
  Timer? _clock, _sunClock;
  late final ValueNotifier<DaySun?> _sun = widget.sun ?? ValueNotifier(null);
  late final ValueNotifier<double> _drift = widget.drift ?? ValueNotifier(0);
  late final DateTime Function() _now = widget.clock ?? DateTime.now;
  late DateTime _resolvedAt; // wall clock at the last _resolve
  DateTime _lastDetail = DateTime.fromMillisecondsSinceEpoch(0);
  late final WindSource _wind = widget.wind ?? WindSource.standard();
  late final int _tier = widget.skyTier ?? debugSkyTier;
  late final Listenable _daySky = Listenable.merge([_sun, _wind, _drift]);
  late final BreathDeps _breath = widget.breath ?? BreathDeps();
  SkyShader? _bakeShader, _classicShader;

  // Reflection sky: base (stage 1) and the image the water samples (stage 2).
  ui.Image? _base, _sky;
  double _baseAz = 0;
  ResolvedScene? _baseScene;
  DateTime? _baseAt; // _resolvedAt of _baseScene
  bool _baseDirty = true, _composeDirty = true, _baking = false, _disposed = false;

  // Per-pixel detail (a port with drawsSkyDetail): what the base was baked
  // for, and the stars and moon the water draws itself.
  bool _baseDetail = false, _baseHidMoon = false;
  SkyDetail? _detail;
  ui.Image? _moonImg;
  // The moon as rendered for _baseAz at the base scene's own time; each
  // drifted detail turns it ([driftedSkyMoon]). _detailAz is the camera
  // bearing the current detail (and the sun) is expressed for.
  SkyMoon? _moon0;
  double _detailAz = 0, _detailDrift = 0;
  double _dpr = 1;

  // Gesture on the moon.
  Size _size = Size.zero;
  bool _onMoon = false;
  double _dragRadius = 0;

  GraphicMode get _mode => widget.controller.mode;
  late final SkyOverride _override = widget.skyOverride ?? debugSkyOverride;
  bool get _timeFixed => widget.now != null || _override.time != null;

  // Ink and glass (owner amendments A1, A3): day or night ink from the
  // sun's altitude with a dead band, and the last look at the drawn sky.
  bool _dayInk = false;
  SkyProbe? _probe;
  Timer? _probeClock;
  bool _probing = false;
  final _skyKey = GlobalKey();
  late final bool _probeOn = widget.probeSky ?? widget.loadSkyShader;

  @override
  void initState() {
    super.initState();
    if (!_override.isEmpty) {
      bakeDiag('sky_override time=${_override.time?.toIso8601String()} '
          'lat=${_override.lat} lon=${_override.lon}');
    }
    _resolve();
    _dayInk = _scene.skyInkBlend >= 0.5;
    if (_probeOn) {
      _probeClock = Timer.periodic(widget.probePeriod, (_) => _probeSky());
      _probeSky();
    }
    _baseAz = viewAzimuth(_scene);
    _detailAz = _baseAz;
    _updateSun();
    bakeDiag('day_sky ${_wind.value} tier=$_tier');
    _shownMode = _mode;
    widget.controller.addListener(_changed);
    // Loads the breath library so a typed "do box breathing" can be matched.
    if (widget.views != null) _breath;
    _focus.addListener(_focusChanged);
    _still.addListener(_changed);
    _water.optics.addListener(_opticsChanged);
    if (!_timeFixed) {
      _clock = Timer.periodic(widget.clockPeriod, (_) {
        if (_inBackground) return;
        setState(_resolve);
        _bake(base: true);
      });
      _sunClock = Timer.periodic(widget.sunPeriod, (_) {
        if (_inBackground) return;
        _redrift();
        _updateSun();
      });
    }
    if (widget.loadSkyShader) {
      // Two wrappers over one program: the bake and Classic set different
      // uniforms on their own FragmentShader instances.
      SkyShader.load().then((s) {
        if (_disposed) {
          s?.dispose();
          return;
        }
        _bakeShader = s;
        _bake(base: true);
      });
      SkyShader.load().then((s) {
        if (_disposed) {
          s?.dispose();
          return;
        }
        setState(() => _classicShader = s);
      });
    } else {
      // With the shader on the way, its load (or failure, null) starts the
      // first bake; a gradient bake before it would be thrown away.
      _bake(base: true);
    }
  }

  bool get _inBackground {
    final life = WidgetsBinding.instance.lifecycleState;
    return life == AppLifecycleState.paused || life == AppLifecycleState.hidden;
  }

  void _resolve() {
    _resolvedAt = _now();
    final t = widget.now ?? _override.time ?? _resolvedAt;
    _scene = CelestialScene.resolve(SkyState.at(t,
        latitudeDeg: _override.lat ?? widget.lat, longitudeDeg: _override.lon ?? widget.lng));
    _drift.value = 0;
    _followSun();
  }

  /// Day ink from 0.6 of the way into the day, night ink from 0.4 back: the
  /// dead band keeps the ink from flickering at dusk. An open view keeps
  /// the ink it opened with.
  void _followSun() {
    if (widget.views?.current != null) return;
    final d = _scene.skyInkBlend;
    if (!_dayInk && d >= 0.6) _dayInk = true;
    if (_dayInk && d <= 0.4) _dayInk = false;
  }

  /// One small look at the sky as drawn (no glass, no text), after the next
  /// frame. Skipped while one is running or the app is in the background.
  void _probeSky() {
    if (_probing || _disposed || _inBackground) return;
    _probing = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _readSky());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  Future<void> _readSky() async {
    try {
      final ro = _skyKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.isEmpty) return;
      final img = await ro.toImage(pixelRatio: SkyProbe.defaultScale);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final (w, h) = (img.width, img.height);
      img.dispose();
      if (_disposed || data == null) return;
      final disc = _moonDisc();
      final probe = SkyProbe.fromRgba(data, w, h,
          discs: [if (disc != null) Rect.fromCircle(center: disc.$1, radius: disc.$2)]);
      if (mounted && !probe.similarTo(_probe)) setState(() => _probe = probe);
    } catch (e) {
      debugPrint('sky_probe_failed (${e.runtimeType})');
    } finally {
      _probing = false;
    }
  }

  /// Wall-clock time since [at] (none when the time is fixed).
  Duration _since(DateTime? at) =>
      _timeFixed || at == null ? Duration.zero : _now().difference(at);

  /// The sun now, in the frame the current detail is drawn for
  /// ([_detailAz]; the base's [_baseAz] until a detail exists): the resolved
  /// scene's day advanced by the wall-clock time since it was resolved. Also
  /// advances [_drift] for Classic. No re-bake.
  void _updateSun() {
    final elapsed = _since(_resolvedAt);
    _drift.value = siderealDriftRad(elapsed);
    final days = elapsed.inMicroseconds / 8.64e10;
    final sun = daySunAt(_scene, _scene.state.timeOfDay + days, _detail == null ? _baseAz : _detailAz);
    // The water reads it through WaterInputs (see _waterView).
    _sun.value = sun;
  }

  /// Per-pixel stars, planets and moon of the base scene turned by the
  /// drift since it was resolved, for a camera re-aimed at the drifted moon.
  /// The base gradient stays in [_baseAz] (at most a minute of drift off,
  /// invisible in a smooth sky) until the next bake.
  SkyDetail _driftedDetail(ResolvedScene s) {
    final d = siderealDriftRad(_since(_baseAt));
    final az = viewAzimuth(s, driftRad: d);
    final m = _moon0;
    _detailAz = az;
    _detailDrift = d;
    _lastDetail = _now();
    return buildSkyDetail(s, az,
        moon: m == null
            ? null
            : driftedSkyMoon(m, fromAz: _baseAz, toAz: az, latRad: s.latitudeRad, driftRad: d),
        devicePixelRatio: _dpr,
        driftRad: d);
  }

  /// Every [IllunisRoot.detailPeriod]: a new drifted detail for the water
  /// (Reflection, per-pixel port, no bake running). Classic needs nothing
  /// here; its painter listens to [_drift].
  void _redrift() {
    final s = _baseScene;
    if (_mode != GraphicMode.reflection || !_baseDetail || _baking || s == null || _detail == null) {
      return;
    }
    if (_now().difference(_lastDetail) < widget.detailPeriod) return;
    _detail = _driftedDetail(s); // _updateSun's notify rebuilds the water
  }

  /// The water, rebuilt on its own when the sun or wind changes. The sun
  /// and clouds (lit by the moon and sky glow at night, drifting with the
  /// same wind) go only to a base baked without the disc (per-pixel path);
  /// before that, and on option A, the bake carries the day sky.
  Widget _waterView() => ListenableBuilder(
      listenable: _daySky,
      builder: (context, _) {
        final day = _baseDetail ? _sun.value : null;
        return _water.build(WaterInputs(
          sky: _sky,
          stillness: _still.value,
          detail: _detail,
          sun: day?.toSkySun(),
          clouds: day == null
              ? null
              : skyClouds(_wind.value.waterVelocity(_baseAz), tier: _tier, night: day.night),
        ));
      });

  GraphicMode? _shownMode;

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // Only a switch into Reflection needs the sky baked; captions and the
    // stillness value do not.
    if (_mode != _shownMode && _mode == GraphicMode.reflection) _bake();
    _shownMode = _mode;
  }

  void _focusChanged() => _bake();

  /// Option B started (the moon's reflected size changes with the pitch) or
  /// fell back to A (the bake must hold the stars and moon again).
  void _opticsChanged() => _bake(base: _water.drawsSkyDetail != _baseDetail);

  void _bake({bool base = false}) {
    if (base) _baseDirty = true;
    _composeDirty = true;
    if (_mode == GraphicMode.reflection) unawaited(_pump());
  }

  /// One bake at a time; requests made meanwhile collapse into the next run.
  Future<void> _pump() async {
    if (_baking) return;
    _baking = true;
    try {
      while (!_disposed && _mode == GraphicMode.reflection && (_baseDirty || _composeDirty)) {
        final detail = _water.drawsSkyDetail;
        final hideMoon = detail && _focus.moon?.defaultImage != null;
        if (_baseDirty || _base == null || detail != _baseDetail || hideMoon != _baseHidMoon) {
          _baseDirty = false;
          final scene = _scene, at = _resolvedAt, az = viewAzimuth(scene);
          final b = await bakeBaseSky(
              scene: scene,
              azimuth: az,
              shader: _bakeShader,
              config: widget.bakeConfig,
              perPixelDetail: detail,
              hideMoon: hideMoon);
          if (_disposed) {
            b.dispose();
            return;
          }
          _base?.dispose(); // only stage 2 reads it, and stage 2 is not running
          _base = b;
          _baseAz = az;
          _baseScene = scene;
          _baseAt = at;
          _baseDetail = detail;
          _baseHidMoon = hideMoon;
          _updateSun(); // the water frame turned with the bake's azimuth
        }
        _composeDirty = false;
        if (_baseDetail) {
          await _composeDetail();
          continue;
        }
        final img = await composeSky(_base!, _baseAz, _moonBake());
        if (_disposed) {
          img.dispose();
          return;
        }
        _show(img, null, null);
      }
    } catch (e) {
      debugPrint('sky_bake_failed (${e.runtimeType})');
    } finally {
      _baking = false;
    }
  }

  /// Stage 2 for a per-pixel port: the moon disc at its on-screen size and
  /// the star list; the water samples the base as it is.
  Future<void> _composeDetail() async {
    final s = _baseScene!;
    final mb = _moonBake(perPixel: true);
    SkyMoon? moon;
    if (mb != null) {
      final o = _water.optics.value;
      final size = _size.isEmpty ? const Size(360, 800) : _size;
      final r = reflectedRadius(s.moonDir, _baseAz, mb.angularRadius, size, o) * _dpr;
      moon = await renderMoonDisc(mb, _baseAz, r);
    }
    final img = _base!.clone();
    if (_disposed) {
      img.dispose();
      moon?.image.dispose();
      return;
    }
    _moon0 = moon;
    _show(img, _driftedDetail(s), moon?.image);
    _updateSun(); // into the detail's frame
  }

  void _show(ui.Image sky, SkyDetail? detail, ui.Image? moonImg) {
    final old = _sky, oldMoon = _moonImg;
    setState(() {
      _sky = sky;
      _detail = detail;
      _moonImg = moonImg;
    });
    // The new images are in use once this frame is drawn; the old ones may
    // still be referenced by the frame before it.
    if (old != null || oldMoon != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        old?.dispose();
        oldMoon?.dispose();
      });
    }
  }

  MoonBake? _moonBake({bool perPixel = false}) {
    final m = _focus.moon, s = _baseScene;
    if (m == null || m.defaultImage == null || s == null) return null;
    // Baked: a hair larger than the shader's disc so its anti-aliased rim is
    // covered. Per pixel the shader's disc is left out, so true size.
    return MoonBake.of(s, m, _focus.angularRadius * (perPixel ? 1.0 : 1.04));
  }

  /// The moon disc on screen for the current mode, in logical pixels.
  (Offset, double)? _moonDisc() {
    if (_focus.moon?.defaultImage == null || _size.isEmpty) return null;
    if (_mode == GraphicMode.classic) {
      final d = _drift.value;
      return classicMoonDisc(_scene, viewAzimuth(_scene, driftRad: d), _size, _focus.angularRadius,
          driftRad: d);
    }
    final s = _baseScene ?? _scene;
    final o = _water.optics.value;
    // Where the water draws it: drifted with the detail, else as baked.
    final (dir, az) = _detail == null
        ? (s.moonDir, _baseAz)
        : (driftedDirection(s.moonDir, s.latitudeRad, _detailDrift), _detailAz);
    final p = reflectedScreenPoint(dir, az, _size, o);
    if (p == null) return null;
    return (p, reflectedRadius(dir, az, _focus.angularRadius, _size, o));
  }

  void _scaleStart(ScaleStartDetails d) {
    final disc = _moonDisc();
    _onMoon = disc != null &&
        (d.localFocalPoint - disc.$1).distance <= math.max(disc.$2 * 1.5, 40);
    if (!_onMoon) return;
    _dragRadius = disc!.$2;
    _focus.beginPinch();
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    if (!_onMoon) return;
    if (d.pointerCount >= 2) {
      _focus.updatePinch(d.scale);
    } else {
      // The reflection is the sky flipped upside down, so a drag on it
      // turns the moon the other way vertically.
      final dy = _mode == GraphicMode.reflection ? -d.focalPointDelta.dy : d.focalPointDelta.dy;
      final r = _moonDisc()?.$2 ?? _dragRadius;
      _focus.drag(d.focalPointDelta.dx, dy, r);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    _sunClock?.cancel();
    _probeClock?.cancel();
    widget.controller.removeListener(_changed);
    _focus.removeListener(_focusChanged);
    _still.removeListener(_changed);
    _water.optics.removeListener(_opticsChanged);
    if (widget.focus == null) _focus.dispose();
    if (widget.stillness == null) _still.dispose();
    if (widget.sun == null) _sun.dispose();
    if (widget.drift == null) _drift.dispose();
    if (widget.wind == null) _wind.dispose();
    widget.ticker?.dispose();
    _bakeShader?.dispose();
    _classicShader?.dispose();
    _base?.dispose();
    _sky?.dispose();
    _moonImg?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final caption = c.caption;
    final reflection = _mode == GraphicMode.reflection;
    _dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final disc = _moonDisc();
    // The ink turns with the sun, slowly; everything below reads it from
    // SkyLight and the theme.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _dayInk ? 1 : 0),
      duration: reduceMotion ? Duration.zero : Motion.ink,
      curve: Motion.inkCurve,
      builder: (context, t, _) {
        final palette = Palette.lerp(Palette.night, Palette.day, t);
        return SkyLight(
          daylight: _scene.skyInkBlend,
          palette: palette,
          discs: [if (disc != null) Rect.fromCircle(center: disc.$1, radius: disc.$2)],
          probe: _probe,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: illunisTheme(palette, day: t >= 0.5),
            themeAnimationDuration: Duration.zero,
            home: _home(c, caption, reflection),
          ),
        );
      },
    );
  }

  Widget _home(AppController c, String? caption, bool reflection) => ColoredBox(
        color: SkyColors.space,
        child: StillnessDebugGate(
          value: _still,
          child: Stack(fit: StackFit.expand, children: [
            LayoutBuilder(builder: (context, box) {
              _size = box.biggest;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _scaleStart,
                onScaleUpdate: _scaleUpdate,
                // The sky alone, for SkyProbe: no glass, no text.
                child: RepaintBoundary(
                  key: _skyKey,
                  child: reflection
                      ? _waterView()
                      : CustomPaint(
                          key: const ValueKey('classic-sky'),
                          size: Size.infinite,
                          painter: ClassicSkyPainter(
                            scene: _scene,
                            drift: _drift,
                            shader: _classicShader,
                            focus: _focus,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                          ),
                        ),
                ),
              );
            }),
            // Fog changes only how the caption leaves, never whether it shows.
            // With the text chat the reply shows in the chat's glass instead.
            if (caption != null && widget.chat == null)
              CenteredCaption(
                child: CaptionView(
                  key: ValueKey(caption),
                  text: caption,
                  fog: c.fogEnabled,
                  // The ink of the sky behind the text once it has been
                  // looked at (_probe); until then from the sun.
                  ink: CaptionInk.forDaylight(_scene.skyInkBlend),
                  followSky: true,
                ),
              ),
            if (widget.chat case final chat?)
              // Full screen: the reply centres on the screen, the input
              // sits at the bottom. Empty space passes touches to the sky.
              Positioned.fill(child: _composer(c, chat)),
            if (widget.views case final views?) _viewLayer(views),
          ]),
        ),
      );

  /// The chat steps back while a view is open: the view's clear sheet
  /// shows the sky, not the chat under it, and takes every touch.
  Widget _composer(AppController c, ChatThread chat) {
    final composer = ChatComposer(
      thread: chat,
      onSubmit: widget.onSubmit ?? (text) => submitTypedTurn(c, chat, text),
    );
    final views = widget.views;
    if (views == null) return composer;
    return ListenableBuilder(
      listenable: views,
      child: composer,
      builder: (context, child) {
        final open = views.current != null;
        final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        return IgnorePointer(
          ignoring: open,
          child: AnimatedOpacity(
            opacity: open ? 0 : 1,
            duration: reduce ? Duration.zero : (open ? Motion.viewIn : Motion.viewOut),
            curve: Motion.viewCurve,
            child: child,
          ),
        );
      },
    );
  }

  /// The open view (only after a yes). Back closes it instead of leaving
  /// the app; it rises in and fades out, or just appears with reduced
  /// motion. A closing view takes no touches.
  Widget _viewLayer(ViewHost views) => ListenableBuilder(
        listenable: views,
        builder: (context, _) {
          final v = views.current;
          final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
          return PopScope(
            canPop: v == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) views.close();
            },
            child: AnimatedSwitcher(
              duration: reduce ? Duration.zero : Motion.viewIn,
              reverseDuration: reduce ? Duration.zero : Motion.viewOut,
              switchInCurve: Motion.viewCurve,
              switchOutCurve: Motion.exitCurve,
              layoutBuilder: (current, previous) =>
                  Stack(fit: StackFit.expand, children: [...previous, ?current]),
              transitionBuilder: _viewTransition,
              child: KeyedSubtree(
                key: ValueKey(v ?? 'no-view'),
                child: switch (v) {
                  null => const SizedBox.shrink(),
                  final v when v.kind == ViewKind.breathwork =>
                    BreathView(key: ValueKey(v), request: v, deps: _breath, onClose: views.close),
                  final v =>
                    logViewFor(v, widget.logs, views.close) ?? PlaceholderView(label: v.label, onClose: views.close),
                },
              ),
            ),
          );
        },
      );

  static Widget _viewTransition(Widget child, Animation<double> a) => AnimatedBuilder(
        animation: a,
        child: child,
        builder: (context, child) => IgnorePointer(
          ignoring: a.status == AnimationStatus.reverse || a.status == AnimationStatus.dismissed,
          child: Opacity(
            opacity: a.value.clamp(0.0, 1.0),
            child: Transform.translate(offset: Offset(0, (1 - a.value) * Motion.viewRise), child: child),
          ),
        ),
      );
}

/// Stand-in for a view whose contents are not built yet (a log view when
/// the app has no log store). It exists so the ask-before-opening
/// mechanism can be seen working: the title, one line, and Close at the
/// top right as in every view.
class PlaceholderView extends StatelessWidget {
  const PlaceholderView({super.key, required this.label, required this.onClose});

  final String label;
  final VoidCallback onClose;

  static const closeKey = ValueKey('placeholder-close');
  static const text = 'Not built yet.';

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    final title = label.isEmpty ? label : label[0].toUpperCase() + label.substring(1);
    return GlassSheet(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(title: title, onClose: onClose, closeKey: closeKey),
        const SizedBox(height: Space.s12),
        Padding(
          padding: const EdgeInsets.only(right: Space.s8),
          child: Text(text, style: TypeScale.body(p.ink2)),
        ),
      ]),
    );
  }
}
