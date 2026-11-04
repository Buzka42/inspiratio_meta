import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_gpu/gpu.dart' as gpu;

import 'cloud_plates.dart';
import 'drop_scheduler.dart';
import 'frame_stats.dart';
import 'heightfield.dart';
import 'sky_detail.dart';
import 'uniforms.dart';
import 'water_camera.dart';

/// Option B water on Flutter GPU (Impeller): a heightfield simulated on the
/// GPU in two ping-pong RGBA16F render targets, then one full-resolution
/// pass that reflects the equirectangular sky off the simulated surface.
///
/// Per [frame]: N simulation passes (fixed [stepsPerSecond], at most
/// [maxStepsPerFrame]), each reading texture A and writing texture B, then
/// one surface pass into a [gpu.GpuImageSurface] frame at the size given to
/// [resize] (the caller passes physical pixels).
///
/// [create] throws when Flutter GPU is unavailable (Impeller off, the
/// EnableFlutterGPU manifest flag missing, the bundle missing, or no float
/// render target); callers fall back to option A.
class GpuWaterRenderer {
  GpuWaterRenderer._(this._simPipe, this._surfPipe, this._noisePipe, this._tri, this._sky, this._format,
      this.camera, this.wave, this.texelBudget, this.heightScale, this._drops);

  static const bundleAsset = 'packages/illunis_gpu/assets/water.shaderbundle';
  static const stepsPerSecond = 120.0;
  static const maxStepsPerFrame = 4;

  /// Frames allowed on the GPU at once; [frame] skips (returns null) beyond
  /// this so the CPU never runs ahead of the GPU.
  static const maxFramesInFlight = 2;

  final gpu.RenderPipeline _simPipe, _surfPipe, _noisePipe;
  final gpu.DeviceBuffer _tri;
  gpu.Texture _sky;
  final gpu.PixelFormat _format;
  final WaterCamera camera;
  final WaveParams wave;
  final int texelBudget;
  final double heightScale;
  final DropScheduler _drops;
  int _inFlight = 0; // surface frames submitted but not yet completed

  /// Frame timing for the debug diagnostic line.
  final stats = FrameStats();

  // Per-pixel sky detail (stars, moon). Empty 1x1 textures stand in when
  // there is none, as every sampler must be bound.
  SkyDetail? _detail;
  gpu.Texture? _starTex, _moonTex, _blank;
  double _gridPixelRad = 0;
  (int, int) _grid = (0, 0);

  // Day: sun and clouds (null: off). The cloud texture is generated on the
  // GPU the first time a daytime frame has clouds; a plate replaces it.
  SkySun? _sun;
  SkyClouds? _clouds;
  gpu.Texture? _cloudGen, _cloudPlate;
  // The two commissioned plates (both or neither); null: procedural clouds.
  (gpu.Texture, gpu.Texture)? _plates;

  /// Side of the generated cloud texture (RGBA8, tileable).
  static const cloudTextureSize = 1024;

  /// Called with a short summary each time the star grid is rebuilt or the
  /// cloud texture is generated (debug diagnostics).
  void Function(String)? onDetailDiag;

  gpu.GpuImageSurface? _surface;
  gpu.Texture? _a, _b; // _a holds the latest state
  int _w = 0, _h = 0, _simW = 0, _simH = 0;
  ui.Rect? _domain;
  double _stepDebt = 0;
  bool _needsClear = false;

  static Future<GpuWaterRenderer> create({
    required ui.Image sky,
    WaterCamera camera = const WaterCamera(),
    WaveParams wave = const WaveParams(),
    int texelBudget = 786432,
    double heightScale = 0.02,
    String asset = bundleAsset,
    DropScheduler? drops,
  }) async {
    wave.validate();
    final ctx = gpu.gpuContext; // Throws if Flutter GPU is not enabled.
    final lib = await gpu.ShaderLibrary.fromAsset(asset);
    final vert = lib?['FullscreenVertex'];
    final simF = lib?['SimStepFragment'];
    final surfF = lib?['WaterSurfaceFragment'];
    final noiseF = lib?['CloudNoiseFragment'];
    if (vert == null || simF == null || surfF == null || noiseF == null) {
      throw StateError('water_shader_bundle_incomplete');
    }
    final format = [gpu.PixelFormat.r16g16b16a16Float, gpu.PixelFormat.r32g32b32a32Float]
        .where((f) => ctx.supportsTextureFormat(f, renderTarget: true))
        .firstOrNull;
    if (format == null) throw StateError('water_no_float_render_target');
    final tri = ctx.createDeviceBufferWithCopy(
        Float32List.fromList([-1, -1, 3, -1, -1, 3]).buffer.asByteData());
    return GpuWaterRenderer._(
      ctx.createRenderPipeline(vert, simF),
      ctx.createRenderPipeline(vert, surfF),
      ctx.createRenderPipeline(vert, noiseF),
      tri,
      gpu.Texture.fromImage(ctx, sky),
      format,
      camera,
      wave,
      texelBudget,
      heightScale,
      drops ?? DropScheduler(),
    );
  }

  /// Replaces the reflected sky without touching the simulation (the app
  /// re-bakes the sky when the clock or the moon zoom changes). [sky] must be
  /// GPU-backed, as for [create].
  void setSky(ui.Image sky) => _sky = gpu.Texture.fromImage(gpu.gpuContext, sky);

  /// Sets the stars and moon drawn per pixel (null: none, the bake has them).
  /// The moon picture must be GPU-backed, as the sky; the caller owns it.
  void setDetail(SkyDetail? detail) {
    _detail = detail;
    _gridPixelRad = 0; // rebuild the star grid on the next frame
    final m = detail?.moon;
    _moonTex = m == null ? null : gpu.Texture.fromImage(gpu.gpuContext, m.image);
  }

  /// Sets the per-pixel sun (null: no sun, and no clouds unless they carry
  /// [SkyClouds.night]). Cheap:
  /// only uniforms change, so it can be called every second as the sun moves.
  void setSun(SkySun? sun) => _sun = sun;

  /// Sets the cloud layer (null: none). Cheap; the cloud texture is made
  /// once, on the first frame that draws clouds.
  void setClouds(SkyClouds? clouds) => _clouds = clouds;

  /// Replaces the generated cloud texture with [plate] (null: back to the
  /// generated one). Same channels: r base density, g detail (0.5 neutral),
  /// b cirrus; tileable, square. Must be GPU-backed, as the sky.
  void setCloudTexture(ui.Image? plate) =>
      _cloudPlate = plate == null ? null : gpu.Texture.fromImage(gpu.gpuContext, plate);

  /// Switches the clouds to the two plates (null: back to procedural
  /// noise). Returns the source in use: procedural when [plates] is null or
  /// its images cannot be wrapped as GPU textures. The caller owns [plates].
  CloudSource setCloudPlates(CloudPlates? plates) {
    _plates = null;
    if (plates == null) return CloudSource.procedural;
    try {
      final ctx = gpu.gpuContext;
      _plates = (gpu.Texture.fromImage(ctx, plates.a), gpu.Texture.fromImage(ctx, plates.b));
    } catch (_) {
      _plates = null;
    }
    final source = cloudSourceFor(plateA: _plates != null, plateB: _plates != null);
    onDetailDiag?.call('cloud_source ${source.name}');
    return source;
  }

  /// The cloud source the next frame uses.
  CloudSource get cloudSource => _plates == null ? CloudSource.procedural : CloudSource.plates;

  bool get _dayOn => (_sun?.dayFade ?? 0) > 0;

  /// Clouds draw by day, or at night when the layer has night light.
  bool get _cloudsOn => _dayOn || (_clouds?.night?.fade ?? 0) > 0;

  gpu.Texture _cloudTexture() => _cloudPlate ?? (_cloudGen ??= _generateClouds());

  // One fragment pass of periodic noise (shaders/cloud_noise.frag), in its
  // own command buffer, submitted before the surface pass that samples it.
  gpu.Texture _generateClouds({double seed = 0}) {
    const n = cloudTextureSize;
    final t = gpu.gpuContext.createTexture(gpu.StorageMode.devicePrivate, n, n,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
        enableRenderTargetUsage: true,
        enableShaderReadUsage: true);
    final cb = gpu.gpuContext.createCommandBuffer();
    final pass = cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: t, loadAction: gpu.LoadAction.dontCare)));
    pass.bindPipeline(_noisePipe);
    pass.setCullMode(gpu.CullMode.none);
    pass.bindVertexBuffer(_triView);
    pass.bindUniform(_noisePipe.fragmentShader.getUniformSlot('NoiseInfo'),
        _uniform(Float32List.fromList([n.toDouble(), n.toDouble(), seed, 0])));
    pass.draw(3);
    final watch = Stopwatch()..start();
    cb.submit(completionCallback: (_) =>
        onDetailDiag?.call('cloud_texture ${n}x$n ms=${watch.elapsedMilliseconds}'));
    return t;
  }

  /// The cloud texture the surface pass samples (generating it if needed).
  @visibleForTesting
  ui.Image debugCloudImage() => _cloudTexture().asImage();

  /// Angle of one output pixel at the screen centre.
  double get pixelRad => _h == 0 ? 0 : camera.fovScale / _h;

  gpu.Texture get _blankTex => _blank ??= () {
        final t = gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, 1, 1,
            enableRenderTargetUsage: false);
        t.overwrite(Uint8List(4).buffer.asByteData());
        return t;
      }();

  void _syncStars() {
    final d = _detail;
    final px = pixelRad;
    if (d == null || d.starCount == 0) {
      _starTex = null;
      _grid = (0, 0);
      return;
    }
    if (px == _gridPixelRad && _starTex != null) return;
    _gridPixelRad = px;
    final watch = Stopwatch()..start();
    final g = StarGrid.build(d, px);
    final t = gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, g.cols, g.height,
        format: gpu.PixelFormat.r32g32b32a32Float, enableRenderTargetUsage: false);
    t.overwrite(g.texels.buffer.asByteData());
    _starTex = t;
    _grid = (g.cols, g.rows);
    onDetailDiag?.call('star_grid stars=${d.starCount} cells=${g.placed} dropped=${g.dropped} '
        '${g.cols}x${g.height} ms=${watch.elapsedMilliseconds}');
  }

  /// Simulated patch in world units (null before the first [resize]).
  ui.Rect? get domain => _domain;
  (int, int) get simSize => (_simW, _simH);

  /// Sets the output size in physical pixels; rebuilds the sim when the
  /// visible footprint changes (a rotation, for example).
  void resize(int width, int height) {
    if (width == _w && height == _h) return;
    _w = width;
    _h = height;
    final s = _surface;
    if (s == null) {
      _surface = gpu.gpuContext.createImageSurface(width, height);
    } else {
      s.resize(width, height);
    }
    final domain = camera.simDomain(width / height);
    final (sw, sh) = simResolution(domain, texelBudget: texelBudget);
    _domain = domain;
    if (sw == _simW && sh == _simH) return;
    _simW = sw;
    _simH = sh;
    gpu.Texture make() => gpu.gpuContext.createTexture(gpu.StorageMode.devicePrivate, sw, sh,
        format: _format, enableRenderTargetUsage: true, enableShaderReadUsage: true);
    _a = make();
    _b = make();
    _needsClear = true;
  }

  // One render pass per command buffer throughout: two passes recorded in
  // one Flutter GPU command buffer crashed the engine (segfault, flutter
  // 3.47.8 tester on Vulkan).
  void _clearSim() {
    for (final t in [_a!, _b!]) {
      final cb = gpu.gpuContext.createCommandBuffer();
      cb.createRenderPass(gpu.RenderTarget.singleColor(
          gpu.ColorAttachment(texture: t, loadAction: gpu.LoadAction.clear)));
      cb.submit();
    }
    _needsClear = false;
  }

  gpu.BufferView get _triView => gpu.BufferView(_tri, offsetInBytes: 0, lengthInBytes: 24);

  // A fresh buffer per pass: the pass keeps it alive until the GPU is done,
  // so no later upload can overwrite uniforms that are still queued. (A
  // shared HostBuffer ring did exactly that when the GPU fell behind.)
  static gpu.BufferView _uniform(Float32List data) {
    final b = gpu.gpuContext.createDeviceBufferWithCopy(data.buffer.asByteData());
    return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: data.lengthInBytes);
  }

  void _step(List<Drop> drops) {
    final src = _a!, dst = _b!;
    final cb = gpu.gpuContext.createCommandBuffer();
    final pass = cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: dst, loadAction: gpu.LoadAction.dontCare)));
    pass.bindPipeline(_simPipe);
    pass.setCullMode(gpu.CullMode.none);
    pass.bindVertexBuffer(_triView);
    final f = _simPipe.fragmentShader;
    pass.bindUniform(f.getUniformSlot('SimInfo'),
        _uniform(packSimInfo(_simW, _simH, wave, drops)));
    pass.bindTexture(f.getUniformSlot('state'), src, sampler: gpu.SamplerOptions());
    pass.draw(3);
    cb.submit();
    _a = dst;
    _b = src;
  }

  /// One simulation step with exactly [drops] (tests compare it with
  /// [stepHeightField]).
  @visibleForTesting
  void debugStep(List<Drop> drops) {
    if (_needsClear) _clearSim();
    _step(drops);
  }

  /// The latest sim state as an image (r = height, g = previous height).
  @visibleForTesting
  ui.Image debugSimImage() => _a!.asImage();

  /// Advances the simulation by [dt] seconds and renders one frame.
  /// [stillness] 0 (mirror calm) to 1 (rough) scales every slope and the
  /// reflection blur.
  /// [walker] is the walker's screen position (0..1, y down), [time] the
  /// clock for the analytic detail. Returns the latest image, or null before
  /// [resize] and while [maxFramesInFlight] frames are still on the GPU.
  ui.Image? frame(
    double dt, {
    required double time,
    ui.Offset walker = const ui.Offset(0.5, 0.8),
    double loudness = 0,
    double vignette = 1,
    double detail = 1,
    double stillness = 1,
  }) {
    final surface = _surface, domain = _domain;
    if (surface == null || domain == null) return null;
    if (_inFlight >= maxFramesInFlight) {
      stats.skipped();
      _stepDebt += dt.clamp(0.0, 0.25) * stepsPerSecond; // catch up next frame
      return null;
    }
    if (_needsClear) _clearSim();

    final aspect = _w / _h;
    final hit = camera.planeHit(walker, aspect);
    final cell = hit == null ? null : worldToCell(hit, domain, _simW, _simH);
    final walkerCell = cell != null &&
            cell.dx >= 0 && cell.dy >= 0 && cell.dx < _simW && cell.dy < _simH
        ? cell
        : null;
    final cellWorld = domain.width / _simW;

    _stepDebt += dt.clamp(0.0, 0.25) * stepsPerSecond;
    var steps = _stepDebt.floor();
    _stepDebt -= steps;
    if (steps > maxStepsPerFrame) steps = maxStepsPerFrame;
    for (var i = 0; i < steps; i++) {
      _step(_drops.next(1 / stepsPerSecond, walkerCell, loudness, _simW, _simH, cellWorld));
    }

    _syncStars();
    final clouds = _cloudsOn ? _clouds : null;
    final plates = clouds == null ? null : _plates;
    // With plates the generated texture is only needed for tier 1's cirrus.
    final cloudTex = clouds == null || (plates != null && clouds.tier < 1) ? null : _cloudTexture();
    final out = surface.acquireNextFrame();
    final cb = gpu.gpuContext.createCommandBuffer();
    final pass = cb.createRenderPass(gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: out.colorTexture, loadAction: gpu.LoadAction.dontCare)));
    pass.bindPipeline(_surfPipe);
    pass.setCullMode(gpu.CullMode.none);
    pass.bindVertexBuffer(_triView);
    final f = _surfPipe.fragmentShader;
    pass.bindUniform(
        f.getUniformSlot('FrameInfo'),
        _uniform(packFrameInfo(
          width: _w,
          height: _h,
          time: time,
          loudness: loudness,
          camera: camera,
          vignette: vignette,
          domain: domain,
          simW: _simW,
          simH: _simH,
          heightScale: heightScale,
          detail: detail,
          stillness: stillness,
          moon: _moonTex == null ? null : _detail?.moon,
          starGrid: _grid,
          pixelRad: pixelRad,
          grain: _detail?.grain ?? 0,
          sun: _sun,
          clouds: _clouds,
          cloudPlateSize: plates == null ? 0 : math.max(plates.$1.width, plates.$2.width),
        )));
    final linear = gpu.SamplerOptions(minFilter: gpu.MinMagFilter.linear, magFilter: gpu.MinMagFilter.linear);
    pass.bindTexture(f.getUniformSlot('heights'), _a!, sampler: linear);
    pass.bindTexture(
        f.getUniformSlot('sky'),
        _sky,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
          widthAddressMode: gpu.SamplerAddressMode.repeat,
        ));
    final nearest = gpu.SamplerOptions();
    pass.bindTexture(f.getUniformSlot('starGrid'), _starTex ?? _blankTex, sampler: nearest);
    pass.bindTexture(f.getUniformSlot('moonDisc'), _moonTex ?? _blankTex, sampler: linear);
    pass.bindTexture(
        f.getUniformSlot('clouds'),
        cloudTex ?? _blankTex,
        sampler: gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.linear,
          magFilter: gpu.MinMagFilter.linear,
          widthAddressMode: gpu.SamplerAddressMode.repeat,
          heightAddressMode: gpu.SamplerAddressMode.repeat,
        ));
    final mirror = gpu.SamplerOptions(
      minFilter: gpu.MinMagFilter.linear,
      magFilter: gpu.MinMagFilter.linear,
      widthAddressMode: gpu.SamplerAddressMode.mirror,
      heightAddressMode: gpu.SamplerAddressMode.mirror,
    );
    pass.bindTexture(f.getUniformSlot('plateA'), plates?.$1 ?? _blankTex, sampler: mirror);
    pass.bindTexture(f.getUniformSlot('plateB'), plates?.$2 ?? _blankTex, sampler: mirror);
    pass.draw(3);
    out.present(cb);
    _inFlight++;
    final submitted = Stopwatch()..start();
    cb.submit(completionCallback: (_) {
      _inFlight--;
      stats.gpu(submitted.elapsedMicroseconds / 1000);
    });
    return surface.currentImage;
  }
}
