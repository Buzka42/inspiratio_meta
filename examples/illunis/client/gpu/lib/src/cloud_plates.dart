import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetBundle;

/// Where the day clouds come from.
enum CloudSource { plates, procedural }

/// Plates only when both loaded; anything less keeps the procedural noise
/// (one plate alone would show as a single repeating tile).
CloudSource cloudSourceFor({required bool plateA, required bool plateB}) =>
    plateA && plateB ? CloudSource.plates : CloudSource.procedural;

/// A decoded plate is usable when square and at least [minSide] texels.
bool plateUsable(int width, int height, {int minSide = CloudPlates.minSide}) =>
    width == height && width >= minSide;

/// The two commissioned cloud plates the surface pass samples
/// (docs/SKY.md (section 3)): clouds on pure black, brightness
/// is opacity. [a] is the base plate, [b] the second deck. Both are
/// GPU-backed decoded images; the holder owns them. Any square size of at
/// least [minSide] works: the shader scales its far-field fade by the side.
class CloudPlates {
  const CloudPlates(this.a, this.b);

  final ui.Image a, b;

  static const minSide = 2048;

  /// App asset keys per plate (client/assets/clouds/, registered in
  /// client/pubspec.yaml), best first: a larger (4096+) plate is used when
  /// the owner adds and registers it under the `_4k` name; the 2048 plates
  /// cumulus_02 and cumulus_06 are the current set.
  static const defaultAssets = [
    ['assets/clouds/cumulus_02_4k.png', 'assets/clouds/cumulus_02.png'],
    ['assets/clouds/cumulus_06_4k.png', 'assets/clouds/cumulus_06.png'],
  ];

  /// Loads plate A then B from [bundle], each from the first of its
  /// candidate keys that decodes to a usable plate. Null when either has
  /// none: the caller keeps procedural clouds.
  static Future<CloudPlates?> load(AssetBundle bundle,
      {List<List<String>> assets = defaultAssets, int minSide = minSide}) async {
    if (assets.length != 2) return null;
    final images = await Future.wait(assets.map((keys) => _first(bundle, keys, minSide)));
    final a = images[0], b = images[1];
    if (cloudSourceFor(plateA: a != null, plateB: b != null) == CloudSource.plates) {
      return CloudPlates(a!, b!);
    }
    a?.dispose();
    b?.dispose();
    return null;
  }

  static Future<ui.Image?> _first(AssetBundle bundle, List<String> keys, int minSide) async {
    for (final k in keys) {
      final img = await _decode(bundle, k);
      if (img == null) continue;
      if (plateUsable(img.width, img.height, minSide: minSide)) return img;
      img.dispose();
    }
    return null;
  }

  static Future<ui.Image?> _decode(AssetBundle bundle, String key) async {
    try {
      final data = await bundle.load(key);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    a.dispose();
    b.dispose();
  }
}
