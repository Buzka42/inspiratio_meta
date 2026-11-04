import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'moon_controller.dart';
import 'moon_mesh.dart';
import 'moon_projection.dart';
import 'moon_shading.dart';

final _identity = Float64List.fromList(const [
  1, 0, 0, 0, //
  0, 1, 0, 0, //
  0, 0, 1, 0, //
  0, 0, 0, 1, //
]);

/// Draws the moon disc from [controller] and turns pinch and drag on its
/// area into view changes. Standalone: it knows nothing about the sky.
class MoonRenderer extends StatefulWidget {
  const MoonRenderer({super.key, required this.controller});

  final MoonController controller;

  @override
  State<MoonRenderer> createState() => _MoonRendererState();
}

class _MoonRendererState extends State<MoonRenderer> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  @override
  void didUpdateWidget(MoonRenderer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) widget.controller.start();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return LayoutBuilder(
      builder: (context, box) {
        c.setScreen(box.biggest, dpr);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) => c.beginPinch(),
          onScaleUpdate: (d) => c.updatePinch(d.scale, d.focalPointDelta),
          child: CustomPaint(size: box.biggest, painter: MoonPainter(c)),
        );
      },
    );
  }
}

/// Paints the default map over the whole disc, then loaded zoom tiles.
/// With a [light], shades the disc with the sky's Lommel-Seeliger model;
/// [dayness] > 0 then fades the night side out (draw inside a layer).
class MoonPainter extends CustomPainter {
  MoonPainter(this.controller, {this.light, this.dayness = 0})
    : super(repaint: controller);

  final MoonController controller;
  final MoonLight? light;
  final double dayness;

  /// Grid of the whole-map mesh (3.75 degrees per quad).
  static const defaultGrid = (96, 48);

  /// Grid of each zoom tile mesh.
  static const tileGrid = (8, 8);

  @override
  void paint(Canvas canvas, Size size) {
    final view = controller.view;
    final radius =
        math.min(size.width, size.height) /
        2 *
        controller.fitFraction *
        view.zoom;
    if (radius <= 0) return;
    final centre = size.center(Offset.zero);
    final proj = MoonProjection(
      centre: centre,
      radius: radius,
      longitudeDeg: view.longitudeDeg,
      latitudeDeg: view.latitudeDeg,
    );
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: centre, radius: radius)),
    );
    final def = controller.defaultImage;
    if (def == null) {
      canvas.drawCircle(
        centre,
        radius,
        Paint()..color = const Color(0xFF8A8A86),
      );
    } else {
      _draw(
        canvas,
        proj,
        MapRegion.whole(controller.manifest),
        def,
        bounds,
        defaultGrid,
      );
    }
    for (final t in controller.drawTiles) {
      _draw(
        canvas,
        proj,
        MapRegion.tile(controller.manifest, t.level, t.column, t.row),
        t.image,
        bounds,
        tileGrid,
      );
    }
    final l = light;
    if (l != null) _shade(canvas, centre, radius, l);
    canvas.restore();
  }

  void _shade(Canvas canvas, Offset centre, double radius, MoonLight l) {
    final m = buildMoonShading(
      centre: centre,
      radius: radius,
      light: l,
      dayness: dayness,
    );
    canvas.drawVertices(m.shade, BlendMode.dst, Paint());
    m.shade.dispose();
    final fade = m.dayFade;
    if (fade != null) {
      canvas.drawVertices(
        fade,
        BlendMode.dst,
        Paint()..blendMode = BlendMode.dstOut,
      );
      fade.dispose();
    }
  }

  void _draw(
    Canvas canvas,
    MoonProjection proj,
    MapRegion region,
    ui.Image image,
    Rect bounds,
    (int, int) grid,
  ) {
    final mesh = buildRegionMesh(
      projection: proj,
      region: region,
      imageWidth: image.width.toDouble(),
      imageHeight: image.height.toDouble(),
      bounds: bounds,
      columns: grid.$1,
      rows: grid.$2,
    );
    if (mesh == null) return;
    final paint = Paint()
      ..shader = ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        _identity,
        filterQuality: FilterQuality.medium,
      );
    final vertices = mesh.toVertices();
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
    vertices.dispose();
  }

  @override
  bool shouldRepaint(MoonPainter old) =>
      old.controller != controller ||
      old.light != light ||
      old.dayness != dayness;
}
