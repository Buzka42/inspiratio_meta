/// Debug-only sky time and place, so a night sky can be reviewed on the phone
/// in daytime. Set with --dart-define:
///   ILLUNIS_SKY_TIME  ISO 8601 with an offset, e.g. 2026-10-24T23:00:00+02:00
///   ILLUNIS_SKY_LAT   latitude, degrees north (-90..90)
///   ILLUNIS_SKY_LON   longitude, degrees east (-180..180)
/// Release and profile builds ignore all three (kDebugMode is a compile-time
/// constant, so the parse is tree-shaken there).
library;

import 'package:flutter/foundation.dart';

/// A fixed time and/or place for the sky. Null fields keep the app's own.
@immutable
class SkyOverride {
  const SkyOverride({this.time, this.lat, this.lon});
  static const none = SkyOverride();

  /// The instant to draw (UTC after parsing; the sky maths uses the instant
  /// and its offset consistently, so the wall-clock zone does not matter).
  final DateTime? time;
  final double? lat, lon;

  bool get isEmpty => time == null && lat == null && lon == null;
}

/// Parses the define values. Returns [SkyOverride.none] when [isDebug] is
/// false. A malformed or out-of-range value is dropped on its own.
SkyOverride skyOverrideFrom({
  required bool isDebug,
  String time = '',
  String lat = '',
  String lon = '',
}) {
  if (!isDebug) return SkyOverride.none;
  double? angle(String s, double limit) {
    final v = double.tryParse(s.trim());
    return v != null && v.abs() <= limit ? v : null;
  }

  // An offset (or Z) is required so the instant is not the phone's zone.
  final t = time.trim();
  final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(t);
  return SkyOverride(
    time: hasZone ? DateTime.tryParse(t)?.toUtc() : null,
    lat: angle(lat, 90),
    lon: angle(lon, 180),
  );
}

/// The override for this build, read once.
final SkyOverride debugSkyOverride = skyOverrideFrom(
  isDebug: kDebugMode,
  time: const String.fromEnvironment('ILLUNIS_SKY_TIME'),
  lat: const String.fromEnvironment('ILLUNIS_SKY_LAT'),
  lon: const String.fromEnvironment('ILLUNIS_SKY_LON'),
);
