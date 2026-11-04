import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_math.dart';
import 'package:illunis_client/sky/wind.dart';

void main() {
  test('default: 4 m/s from the west', () {
    expect(Wind.westerly.speedMps, 4);
    expect(Wind.westerly.fromRad, closeTo(270 * degToRad, 1e-12));
    expect(WindSource().value, Wind.westerly);
  });

  test('water-frame velocity points where the wind blows to', () {
    const w = Wind.westerly; // blows toward the east
    // Facing north: east is to the right.
    var (x, z) = w.waterVelocity(0);
    expect(x, closeTo(4, 1e-9));
    expect(z, closeTo(0, 1e-9));
    // Facing east: the clouds move away from the camera.
    (x, z) = w.waterVelocity(math.pi / 2);
    expect(x, closeTo(0, 1e-9));
    expect(z, closeTo(4, 1e-9));
    // Facing south: east is to the left; the scale converts metres.
    (x, z) = w.waterVelocity(math.pi, unitsPerMetre: 0.5);
    expect(x, closeTo(-2, 1e-9));
    expect(z, closeTo(0, 1e-9));
    // A north wind facing north comes toward the camera.
    (x, z) = const Wind(fromRad: 0, speedMps: 3).waterVelocity(0);
    expect(x, closeTo(0, 1e-9));
    expect(z, closeTo(-3, 1e-9));
  });

  test('the debug define is parsed in debug builds only', () {
    final w = windOverrideFrom(isDebug: true, spec: ' 90 , 7.5 ');
    expect(w, isNotNull);
    expect(w!.fromRad, closeTo(math.pi / 2, 1e-12));
    expect(w.speedMps, 7.5);
    expect(windOverrideFrom(isDebug: false, spec: '90,7.5'), isNull);
    expect(windOverrideFrom(isDebug: true), isNull);
  });

  test('bad define values are dropped', () {
    for (final s in ['90', '90,', 'west,4', '400,4', '-10,4', '90,-1', '90,99', '90,4,1', 'NaN,4']) {
      expect(windOverrideFrom(isDebug: true, spec: s), isNull, reason: s);
    }
  });

  test('a source notifies when weather or settings change it', () {
    final src = WindSource();
    var heard = 0;
    src.addListener(() => heard++);
    src.value = const Wind(fromRad: 0, speedMps: 2);
    src.value = const Wind(fromRad: 0, speedMps: 2); // same value: no change
    expect(heard, 1);
    src.dispose();
  });
}
