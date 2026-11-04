import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/sun_position.dart';

/// Classic mode. Gradient placeholder by day (until a licensed photo is
/// added), procedural stars by night. Sun and moon placed from [sunPosition]
/// and [moonPosition]. Pass [now] for deterministic tests.
class ClassicSky extends StatelessWidget {
  const ClassicSky({super.key, required this.lat, required this.lng, this.now});
  final double lat, lng;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final t = now ?? DateTime.now();
    return CustomPaint(
      painter: ClassicSkyPainter(sunPosition(t, lat, lng), moonPosition(t, lat, lng)),
      size: Size.infinite,
    );
  }
}

class ClassicSkyPainter extends CustomPainter {
  ClassicSkyPainter(this.sun, this.moon);
  final SkyPosition sun, moon;

  /// 0 = night, 1 = day, smooth through twilight (sun -6..+6 degrees).
  double get daylight => ((sun.altitudeDeg + 6) / 12).clamp(0.0, 1.0);

  Offset _place(SkyPosition p, Size s) => Offset(
        s.width * (p.azimuth / (2 * math.pi)),
        s.height * (1 - (p.altitudeDeg.clamp(-10, 90) + 10) / 100),
      );

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final k = daylight;
    final top = Color.lerp(const Color(0xFF050B1E), const Color(0xFF3F7FD0), k)!;
    final bottom = Color.lerp(const Color(0xFF16213F), const Color(0xFFBFE0F5), k)!;
    canvas.drawRect(
        r,
        Paint()
          ..shader = LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom])
              .createShader(r));
    if (k < 1) {
      final rng = math.Random(7); // fixed seed: stable star field
      final p = Paint();
      for (var i = 0; i < 220; i++) {
        final tw = 0.4 + 0.6 * rng.nextDouble();
        p.color = Colors.white.withValues(alpha: (1 - k) * tw);
        canvas.drawCircle(
            Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height * 0.85),
            0.4 + rng.nextDouble() * 1.1,
            p);
      }
    }
    if (sun.altitudeDeg > -2) {
      canvas.drawCircle(_place(sun, size), 22, Paint()..color = const Color(0xFFFFE9A8));
    }
    if (moon.altitudeDeg > -2) {
      canvas.drawCircle(_place(moon, size), 14,
          Paint()..color = const Color(0xFFEDEFF5).withValues(alpha: 1 - 0.6 * k));
    }
  }

  @override
  bool shouldRepaint(ClassicSkyPainter o) => o.sun != sun || o.moon != moon;
}
