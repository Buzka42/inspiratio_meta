import 'dart:async';
import 'dart:ui' as ui;

import 'package:illunis_client/moon_render/tile_loader.dart';

ui.Image solidImage(int w, int h, [int argb = 0xFF808080]) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawPaint(ui.Paint()..color = ui.Color(argb));
  final picture = rec.endRecording();
  final image = picture.toImageSync(w, h);
  picture.dispose();
  return image;
}

/// Loader whose loads finish only when the test says so.
class FakeLoader implements MoonTileLoader {
  FakeLoader({this.immediate = false});

  /// When true, every load completes at once with a small image.
  final bool immediate;
  final requests = <String>[];
  final pending = <String, Completer<ui.Image>>{};
  final delivered = <String, ui.Image>{};

  @override
  Future<ui.Image> load(String file) {
    requests.add(file);
    if (immediate) return Future.value(_make(file));
    final c = Completer<ui.Image>();
    pending[file] = c;
    return c.future;
  }

  ui.Image _make(String file) {
    final img = file == 'default.jpg' ? solidImage(64, 32) : solidImage(8, 8);
    delivered[file] = img;
    return img;
  }

  void complete(String file) => pending.remove(file)!.complete(_make(file));

  void fail(String file) =>
      pending.remove(file)!.completeError(StateError('missing'));

  /// Completes every pending load, including ones started while doing so.
  Future<void> completeAll() async {
    while (pending.isNotEmpty) {
      for (final f in pending.keys.toList()) {
        complete(f);
      }
      await Future<void>.delayed(Duration.zero);
    }
  }
}
