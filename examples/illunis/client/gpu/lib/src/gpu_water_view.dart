import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'cloud_plates.dart';
import 'gpu_water_renderer.dart';
import 'sky_detail.dart';
import 'water_camera.dart';

typedef GpuWaterFactory = Future<GpuWaterRenderer> Function(ui.Image sky, WaterCamera camera);

Future<GpuWaterRenderer> _defaultFactory(ui.Image sky, WaterCamera camera) =>
    GpuWaterRenderer.create(sky: sky, camera: camera);

/// Full-screen option B water. Shows [fallback] (option A) while the sky or
/// the GPU renderer is loading, and for good if Flutter GPU is unavailable or
/// a frame fails. Renders at the device's physical resolution.
///
/// Day sky: pass [sun] and [clouds] (null turns each off). Changing them is
/// cheap (uniforms only, no star-grid rebuild or re-bake), so the app can
/// rebuild with a new [SkySun] about once per second as the sun moves; the
/// cloud drift is computed per frame from [SkyClouds.windVelocity] and the
/// widget's own clock. Clouds need a sun with dayFade > 0, or
/// [SkyClouds.night]; with neither the frame is exactly the night frame.
///
/// Cloud plates: the first time [clouds] is non-null the widget loads
/// [cloudPlateAssets] from the [DefaultAssetBundle]; if both decode, the
/// clouds come from the plates, otherwise they stay procedural.
class GpuWater extends StatefulWidget {
  const GpuWater({
    super.key,
    required this.sky,
    required this.fallback,
    this.walker = const Offset(0.5, 0.8),
    this.loudness = 0,
    this.vignette = 1,
    this.stillness = 1,
    this.camera = const WaterCamera(),
    this.factory = _defaultFactory,
    this.detail,
    this.sun,
    this.clouds,
    this.onFailed,
    this.cloudPlateAssets = CloudPlates.defaultAssets,
  });

  /// Candidate asset keys for cloud plates A and B, best first; empty
  /// keeps procedural clouds.
  final List<List<String>> cloudPlateAssets;

  /// The sun drawn per pixel and lighting the clouds; null for none.
  final SkySun? sun;

  /// The moving cloud layer; null for none.
  final SkyClouds? clouds;

  /// Stars and moon drawn per pixel; null when [sky] holds them.
  final SkyDetail? detail;

  /// Called once when the GPU path gives up (start or a later frame).
  final VoidCallback? onFailed;

  /// Equirectangular (2:1) sky; must be GPU-backed (from Picture.toImage or
  /// a decoded image, not toImageSync).
  final ui.Image? sky;
  final WidgetBuilder fallback;
  final Offset walker; // screen position, normalised 0..1
  final double loudness; // 0..1
  final double vignette; // 0..1
  final double stillness; // 0 mirror calm .. 1 rough
  final WaterCamera camera;
  final GpuWaterFactory factory;

  @override
  State<GpuWater> createState() => _GpuWaterState();
}

class _GpuWaterState extends State<GpuWater> with SingleTickerProviderStateMixin {
  GpuWaterRenderer? _r;
  ui.Image? _img;
  bool _failed = false;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  Size _physical = Size.zero;
  CloudPlates? _plates;
  bool _platesRequested = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(GpuWater old) {
    super.didUpdateWidget(old);
    final r = _r;
    final sky = widget.sky;
    if (r != null) {
      if (old.sun != widget.sun) r.setSun(widget.sun);
      if (old.clouds != widget.clouds) r.setClouds(widget.clouds);
      _maybeLoadPlates();
    }
    if (r != null && old.detail != widget.detail) {
      try {
        r.setDetail(widget.detail);
      } catch (e) {
        _fail('gpu_water_frame_failed', e);
        return;
      }
    }
    if (old.camera == widget.camera && old.sky != sky && r != null && sky != null) {
      // A re-baked sky: swap the texture and keep the running simulation.
      try {
        r.setSky(sky);
      } catch (e) {
        _fail('gpu_water_frame_failed', e);
      }
      return;
    }
    if (old.sky != widget.sky || old.camera != widget.camera) {
      _r = null;
      _ticker.stop();
      _load();
    }
  }

  void _load() {
    final sky = widget.sky;
    if (sky == null || _failed) return;
    widget.factory(sky, widget.camera).then((r) {
      if (!mounted || widget.sky != sky) return;
      if (kDebugMode) r.onDetailDiag = (m) => debugPrint('illunis_diag: water gpu $m');
      r
        ..setSun(widget.sun)
        ..setClouds(widget.clouds);
      if (_plates != null) r.setCloudPlates(_plates);
      try {
        r.setDetail(widget.detail);
      } catch (e) {
        _fail('gpu_water_unavailable', e);
        return;
      }
      setState(() => _r = r);
      _maybeLoadPlates();
      _last = Duration.zero;
      if (!_ticker.isActive) _ticker.start();
    }).catchError((Object e) => _fail('gpu_water_unavailable', e));
  }

  // Once per widget, when clouds are first wanted; a failure is final for
  // this widget (procedural clouds).
  void _maybeLoadPlates() {
    if (_platesRequested || widget.clouds == null || widget.cloudPlateAssets.isEmpty) return;
    _platesRequested = true;
    CloudPlates.load(DefaultAssetBundle.of(context), assets: widget.cloudPlateAssets).then((p) {
      if (!mounted) {
        p?.dispose();
        return;
      }
      _plates = p;
      final r = _r;
      if (r == null) return;
      final source = r.setCloudPlates(p);
      if (kDebugMode) debugPrint('illunis_diag: water gpu clouds=${source.name}');
    });
  }

  void _fail(String code, Object e) {
    // Code and error type only; no frame data.
    debugPrint('$code (${e.runtimeType})');
    if (kDebugMode) debugPrint('illunis_diag: water gpu $code ($e)');
    if (!mounted || _failed) return;
    _ticker.stop();
    setState(() => _failed = true);
    widget.onFailed?.call();
  }

  void _tick(Duration elapsed) {
    final r = _r;
    if (r == null || _physical.isEmpty) return;
    final dt = _last == Duration.zero ? 1 / 60 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (kDebugMode) {
      r.stats.tick(dt * 1000);
      final line = r.stats.take();
      if (line != null) debugPrint('illunis_diag: water gpu $line ${_physical.width.round()}x${_physical.height.round()}');
    }
    try {
      r.resize(_physical.width.round(), _physical.height.round());
      final img = r.frame(dt,
          time: elapsed.inMicroseconds / 1e6,
          walker: widget.walker,
          loudness: widget.loudness,
          vignette: widget.vignette,
          stillness: widget.stillness);
      if (img == null) return;
      final old = _img;
      if (old == null && kDebugMode) debugPrint('illunis_diag: water gpu first_frame');
      setState(() => _img = img);
      old?.dispose(); // RawImage holds its own clone.
    } catch (e) {
      _fail('gpu_water_frame_failed', e);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _img?.dispose();
    _plates?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _r == null) return widget.fallback(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, c) {
      _physical = Size(c.maxWidth * dpr, c.maxHeight * dpr);
      final img = _img;
      if (img == null) return widget.fallback(context);
      return RawImage(
        key: const ValueKey('water-gpu'),
        image: img,
        width: c.maxWidth,
        height: c.maxHeight,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.none, // 1:1 with physical pixels
      );
    });
  }
}
