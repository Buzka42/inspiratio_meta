import 'dart:math' as math;

/// Sun and moon position, after the suncalc algorithm (Vladimir Agafonkin).
/// Azimuth is measured from north, clockwise, in radians. Altitude is above
/// the horizon in radians, without atmospheric refraction.
class SkyPosition {
  const SkyPosition(this.azimuth, this.altitude);
  final double azimuth;
  final double altitude;
  double get altitudeDeg => altitude * 180 / math.pi;
  double get azimuthDeg => azimuth * 180 / math.pi;
}

const _rad = math.pi / 180;
const _e = _rad * 23.4397; // obliquity of the Earth

double _toDays(DateTime t) =>
    t.toUtc().millisecondsSinceEpoch / 86400000.0 - 0.5 + 2440588 - 2451545;

double _ra(double l, double b) =>
    math.atan2(math.sin(l) * math.cos(_e) - math.tan(b) * math.sin(_e), math.cos(l));
double _dec(double l, double b) =>
    math.asin(math.sin(b) * math.cos(_e) + math.cos(b) * math.sin(_e) * math.sin(l));

SkyPosition _horizontal(double d, double ra, double dec, double lat, double lng) {
  final h = _rad * (280.16 + 360.9856235 * d) - (-_rad * lng) - ra;
  final phi = _rad * lat;
  final az = math.atan2(math.sin(h), math.cos(h) * math.sin(phi) - math.tan(dec) * math.cos(phi));
  final alt = math.asin(math.sin(phi) * math.sin(dec) + math.cos(phi) * math.cos(dec) * math.cos(h));
  // suncalc measures azimuth from south; convert to north-based.
  return SkyPosition((az + math.pi) % (2 * math.pi), alt);
}

SkyPosition sunPosition(DateTime time, double lat, double lng) {
  final d = _toDays(time);
  final m = _rad * (357.5291 + 0.98560028 * d);
  final c = _rad * (1.9148 * math.sin(m) + 0.02 * math.sin(2 * m) + 0.0003 * math.sin(3 * m));
  final l = m + c + _rad * 102.9372 + math.pi;
  return _horizontal(d, _ra(l, 0), _dec(l, 0), lat, lng);
}

SkyPosition moonPosition(DateTime time, double lat, double lng) {
  final d = _toDays(time);
  final lm = _rad * (218.316 + 13.176396 * d);
  final mm = _rad * (134.963 + 13.064993 * d);
  final f = _rad * (93.272 + 13.229350 * d);
  final l = lm + _rad * 6.289 * math.sin(mm);
  final b = _rad * 5.128 * math.sin(f);
  return _horizontal(d, _ra(l, b), _dec(l, b), lat, lng);
}
