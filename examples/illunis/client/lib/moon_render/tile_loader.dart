import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Loads one map image named by its manifest file (for example
/// `default.jpg` or `tiles/L0_3_2.jpg`).
abstract interface class MoonTileLoader {
  Future<ui.Image> load(String file);
}

/// Loads bundled moon images from assets/moon/.
///
/// The asset bytes go straight into an engine buffer (no copy on the Dart
/// heap) and the engine decodes the JPEG on its own worker threads, so the
/// UI isolate only awaits futures. A Dart `compute` isolate is not used:
/// dart:ui image decoding is not available there, and decoding in pure
/// Dart would need a JPEG package.
class AssetMoonTileLoader implements MoonTileLoader {
  AssetMoonTileLoader({AssetBundle? bundle, this.root = 'assets/moon/'})
    : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final String root;

  @override
  Future<ui.Image> load(String file) async {
    final buffer = await _bundle.loadBuffer('$root$file');
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
