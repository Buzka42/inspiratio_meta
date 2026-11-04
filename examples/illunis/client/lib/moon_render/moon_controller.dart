import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../moon/moon_manifest.dart';
import '../moon/moon_view.dart';
import '../moon/tile_cache.dart';
import '../moon/tile_selector.dart';
import '../moon/voice_zoom.dart';
import 'tile_loader.dart';

/// A loaded zoom tile ready to draw.
class MoonDrawTile {
  const MoonDrawTile(this.level, this.column, this.row, this.file, this.image);
  final MoonLevel level;
  final int column, row;
  final String file;
  final ui.Image image;
}

/// Owns the moon view state, tile choice, tile cache and tile loading.
///
/// The default map is always drawn; zoom tiles are drawn on top as they
/// arrive. Evicted tiles have their ui.Image disposed.
class MoonController extends ChangeNotifier {
  MoonController({
    required this.manifest,
    required this.loader,
    int cacheCapacity = 32,
    this.maxConcurrentLoads = 4,
    this.fitFraction = 0.92,
    this.onTileReady,
    this.onTileFreed,
  }) : assert(maxConcurrentLoads > 0, 'need at least one load slot'),
       selector = TileSelector(manifest),
       view = MoonView() {
    cache = TileCache<ui.Image>(capacity: cacheCapacity, onEvict: _free);
    for (final level in manifest.levels) {
      for (var r = 0; r < level.rows; r++) {
        for (var c = 0; c < level.columns; c++) {
          _refs[level.fileAt(c, r)] = (level, c, r);
        }
      }
    }
  }

  final MoonManifest manifest;
  final MoonTileLoader loader;
  final TileSelector selector;
  final MoonView view;
  late final TileCache<ui.Image> cache;
  final int maxConcurrentLoads;

  /// Share of the short side the disc fills at zoom 1.
  final double fitFraction;

  /// Called with the manifest file name when an image finishes loading.
  final void Function(String file)? onTileReady;

  /// Called after an evicted tile's image is disposed.
  final void Function(String file)? onTileFreed;

  final _refs = <String, (MoonLevel, int, int)>{};
  final _inFlight = <String>{};
  final _failed = <String>{};
  List<String> _queue = const [];
  List<String> _wanted = const [];
  ui.Image? _defaultImage;
  bool _defaultRequested = false;
  bool _disposed = false;
  MoonScreen? _screen;
  ui.Size? _logicalSize;
  double _dpr = 1;

  ui.Image? get defaultImage => _defaultImage;
  MoonScreen? get screen => _screen;

  /// Tile files the current view wants (empty while the default map
  /// is enough).
  List<String> get wantedTiles => List.unmodifiable(_wanted);
  Set<String> get loadingTiles => Set.unmodifiable(_inFlight);

  /// Wanted tiles that are loaded, in draw order.
  List<MoonDrawTile> get drawTiles => [
    for (final file in _wanted)
      if (cache.contains(file))
        MoonDrawTile(
          _refs[file]!.$1,
          _refs[file]!.$2,
          _refs[file]!.$3,
          file,
          cache.get(file)!,
        ),
  ];

  /// Starts loading the default map. Safe to call more than once.
  Future<void> start() async {
    if (_defaultRequested || _disposed) return;
    _defaultRequested = true;
    final file = manifest.defaultMap.files.first;
    try {
      final image = await loader.load(file);
      if (_disposed) {
        image.dispose();
        return;
      }
      _defaultImage = image;
      onTileReady?.call(file);
      notifyListeners();
    } catch (_) {
      _defaultRequested = false;
      debugPrint('moon_default_load_failed');
    }
  }

  /// Sets the drawing area. Does not notify: safe to call from layout.
  void setScreen(ui.Size logicalSize, double devicePixelRatio) {
    if (logicalSize == _logicalSize && devicePixelRatio == _dpr) return;
    _logicalSize = logicalSize;
    _dpr = devicePixelRatio;
    final s = MoonScreen(
      logicalSize.width * devicePixelRatio,
      logicalSize.height * devicePixelRatio,
      fitFraction: fitFraction,
    );
    _screen = s;
    if (s.fitRadius > 0) view.maxZoom = selector.maxZoom(s);
    _refresh();
  }

  void beginPinch() => view.beginPinch();

  /// One pinch or drag update: [scale] is cumulative since [beginPinch],
  /// [focalDelta] is the finger movement in logical pixels.
  void updatePinch(double scale, ui.Offset focalDelta) {
    view.updatePinch(scale);
    final s = _screen;
    if (s != null) view.pan(focalDelta.dx * _dpr, focalDelta.dy * _dpr, s);
    _changed();
  }

  /// Routes a spoken transcript through the voice zoom parser. Returns
  /// true when it was a moon zoom command.
  bool handleTranscript(String transcript) {
    final action = parseMoonZoom(transcript);
    if (action == null) return false;
    view.apply(action);
    _changed();
    return true;
  }

  void _changed() {
    _refresh();
    notifyListeners();
  }

  void _refresh() {
    final s = _screen;
    if (s == null || _disposed) return;
    final sel = selector.select(view, s);
    _wanted = sel.level.isDefault ? const [] : sel.files;
    cache.setVisible(_wanted);
    _queue = [
      for (final f in _wanted)
        if (!cache.contains(f) &&
            !_inFlight.contains(f) &&
            !_failed.contains(f))
          f,
    ];
    _pump();
  }

  void _pump() {
    while (_inFlight.length < maxConcurrentLoads && _queue.isNotEmpty) {
      final file = _queue.first;
      _queue = _queue.sublist(1);
      _inFlight.add(file);
      loader
          .load(file)
          .then(
            (image) => _loaded(file, image),
            onError: (Object _) {
              _inFlight.remove(file);
              _failed.add(file);
              debugPrint('moon_tile_load_failed');
              if (!_disposed) _pump();
            },
          );
    }
  }

  void _loaded(String file, ui.Image image) {
    _inFlight.remove(file);
    if (_disposed) {
      image.dispose();
      return;
    }
    cache.put(file, image);
    onTileReady?.call(file);
    notifyListeners();
    _pump();
  }

  void _free(String file, ui.Image image) {
    image.dispose();
    onTileFreed?.call(file);
  }

  @override
  void dispose() {
    _disposed = true;
    _queue = const [];
    _defaultImage?.dispose();
    _defaultImage = null;
    for (final name in cache.names.toList()) {
      cache.get(name)?.dispose();
    }
    super.dispose();
  }
}
