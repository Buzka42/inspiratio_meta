import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/sky_debug_override.dart';

void main() {
  const time = '2026-10-24T23:00:00+02:00';

  test('debug builds apply the time and place', () {
    final o = skyOverrideFrom(isDebug: true, time: time, lat: '52.2', lon: '21.0');
    expect(o.time, DateTime.utc(2026, 10, 24, 21));
    expect(o.lat, 52.2);
    expect(o.lon, 21.0);
    expect(o.isEmpty, isFalse);
  });

  test('release logic ignores the defines', () {
    final o = skyOverrideFrom(isDebug: false, time: time, lat: '52.2', lon: '21.0');
    expect(o.isEmpty, isTrue);
  });

  test('bad values are dropped one by one', () {
    final o = skyOverrideFrom(
        isDebug: true, time: '2026-10-24T23:00:00', lat: '95', lon: 'east');
    expect(o.time, isNull, reason: 'no offset: the zone would be the phone');
    expect(o.lat, isNull);
    expect(o.lon, isNull);
    expect(skyOverrideFrom(isDebug: true, time: '2026-10-24T21:00:00Z').time,
        DateTime.utc(2026, 10, 24, 21));
    expect(skyOverrideFrom(isDebug: true).isEmpty, isTrue);
  });
}
