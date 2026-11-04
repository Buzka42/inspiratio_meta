/// Six thin line glyphs drawn in code (no icon font, no filled shapes): a
/// 20 px glyph with a 1.5 px stroke and round caps, for a 48 px target.
library;

import 'package:flutter/widgets.dart';

enum IllunisGlyph { send, back, forward, close, pause, play }

class IllunisIcon extends StatelessWidget {
  const IllunisIcon(this.glyph, {super.key, required this.color, this.size = 20});

  final IllunisGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CustomPaint(size: Size.square(size), painter: GlyphPainter(glyph, color)),
      );
}

class GlyphPainter extends CustomPainter {
  const GlyphPainter(this.glyph, this.color);

  final IllunisGlyph glyph;
  final Color color;

  static const double stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 20; // drawn on a 20 x 20 grid
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Path line(List<Offset> pts, {bool close = false}) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final q in pts.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      if (close) path.close();
      return path;
    }

    final paths = switch (glyph) {
      IllunisGlyph.send => [line([p(10, 16), p(10, 4)]), line([p(5, 9), p(10, 4), p(15, 9)])],
      IllunisGlyph.back => [line([p(12.5, 4), p(7, 10), p(12.5, 16)])],
      IllunisGlyph.forward => [line([p(7.5, 4), p(13, 10), p(7.5, 16)])],
      IllunisGlyph.close => [line([p(5, 5), p(15, 15)]), line([p(15, 5), p(5, 15)])],
      IllunisGlyph.pause => [line([p(7, 5), p(7, 15)]), line([p(13, 5), p(13, 15)])],
      IllunisGlyph.play => [line([p(7, 4.5), p(15.5, 10), p(7, 15.5)], close: true)],
    };
    for (final path in paths) {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(GlyphPainter old) => old.glyph != glyph || old.color != color;
}
