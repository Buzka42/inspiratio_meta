import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/core/sun_position.dart';

void main() {
  // Greenwich observatory.
  const lat = 51.4779, lng = -0.0015;

  test('June solstice 2024 solar noon: altitude ~ 90-lat+23.44 = 62 deg, due south', () {
    final p = sunPosition(DateTime.utc(2024, 6, 21, 12, 2), lat, lng);
    expect(p.altitudeDeg, closeTo(61.96, 0.6));
    expect(p.azimuthDeg, closeTo(180, 3));
  });

  test('December solstice 2024 solar noon: altitude ~ 90-lat-23.44 = 15 deg', () {
    final p = sunPosition(DateTime.utc(2024, 12, 21, 11, 58), lat, lng);
    expect(p.altitudeDeg, closeTo(15.1, 0.6));
  });

  test('sun is below the horizon at local midnight', () {
    expect(sunPosition(DateTime.utc(2024, 6, 21, 0, 0), lat, lng).altitudeDeg, lessThan(0));
  });

  test('moon altitude stays within physical bounds', () {
    final p = moonPosition(DateTime.utc(2024, 6, 21, 22), lat, lng);
    expect(p.altitudeDeg, inInclusiveRange(-90, 90));
  });
}
