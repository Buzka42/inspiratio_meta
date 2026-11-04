import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../moon/moon_manifest.dart';
import '../moon_render/moon_controller.dart';
import '../moon_render/tile_loader.dart';

/// The bundled moon map's controller, or null when the manifest is missing
/// or rejected (the sky shader's own moon is drawn then). Starts loading the
/// default map without waiting for it; the main view re-bakes when it lands.
/// Logs a code only.
Future<MoonController?> loadBundledMoon({AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  try {
    final result = parseMoonManifest(await b.loadString('assets/moon/manifest.json'));
    switch (result) {
      case ManifestOk(:final manifest):
        final c = MoonController(manifest: manifest, loader: AssetMoonTileLoader(bundle: b));
        unawaited(c.start());
        return c;
      case ManifestRejected(:final code):
        debugPrint('moon_manifest_rejected ${code.name}');
        return null;
    }
  } catch (e) {
    debugPrint('moon_manifest_unavailable (${e.runtimeType})');
    return null;
  }
}
