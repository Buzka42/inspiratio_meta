/// Wind for the sky's drifting clouds, day and night. One [WindSource] feeds
/// the cloud layer; today it holds a fixed default (or a debug define), later weather
/// or the owner's vitals settings set its value.
///
/// Debug builds only: `--dart-define=ILLUNIS_SKY_WIND=<deg>,<m/s>`, the
/// bearing the wind comes FROM (0 north, 90 east) and its speed. Release
/// and profile builds ignore it; a malformed value is dropped.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'celestial_math.dart';

@immutable
class Wind {
  const Wind({required this.fromRad, required this.speedMps});

  /// The default: 4 m/s from the west.
  static const westerly = Wind(fromRad: 1.5 * math.pi, speedMps: 4);

  /// Bearing the wind comes from, radians from north via east.
  final double fromRad;
  final double speedMps;

  /// Horizontal velocity in the water frame (x right, z forward) for a
  /// camera facing [azimuth], in world units per second ([unitsPerMetre]
  /// world units per metre). The air moves toward fromRad + pi.
  (double, double) waterVelocity(double azimuth, {double unitsPerMetre = 1}) {
    final to = fromRad + math.pi;
    final s = speedMps * unitsPerMetre;
    // World horizontal frame: x east, z south; a bearing b points (sin b, -cos b).
    final ex = math.sin(to) * s, ez = -math.cos(to) * s;
    final rx = math.cos(azimuth), rz = math.sin(azimuth); // camera right
    final fx = math.sin(azimuth), fz = -math.cos(azimuth); // camera forward
    return (ex * rx + ez * rz, ex * fx + ez * fz);
  }

  @override
  bool operator ==(Object other) =>
      other is Wind && other.fromRad == fromRad && other.speedMps == speedMps;

  @override
  int get hashCode => Object.hash(fromRad, speedMps);

  @override
  String toString() =>
      'Wind(from ${(fromRad * radToDeg).toStringAsFixed(0)} deg, ${speedMps.toStringAsFixed(1)} m/s)';
}

/// The wind the clouds follow. Listeners hear every change.
class WindSource extends ValueNotifier<Wind> {
  WindSource([super.value = Wind.westerly]);

  /// [debugWind] if the define is set, else [Wind.westerly].
  factory WindSource.standard() => WindSource(debugWind ?? Wind.westerly);
}

/// Parses `<deg>,<m/s>`. Null when [isDebug] is false or the value is bad
/// (bearing outside 0..360, speed outside 0..60 m/s, or not two numbers).
Wind? windOverrideFrom({required bool isDebug, String spec = ''}) {
  if (!isDebug) return null;
  final parts = spec.split(',');
  if (parts.length != 2) return null;
  final deg = double.tryParse(parts[0].trim());
  final mps = double.tryParse(parts[1].trim());
  // Written as "inside" tests so NaN fails them too.
  final ok = deg != null && mps != null && deg >= 0 && deg <= 360 && mps >= 0 && mps <= 60;
  if (!ok) return null;
  return Wind(fromRad: deg * degToRad, speedMps: mps);
}

/// The define for this build, read once.
final Wind? debugWind = windOverrideFrom(
  isDebug: kDebugMode,
  spec: const String.fromEnvironment('ILLUNIS_SKY_WIND'),
);
