import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_state.dart';

const _base = SkyState(
  timeOfDay: 0.9,
  dayOfYear: 172,
  epochDays: 9668,
  latitudeDeg: 52.23,
  moonPhase: 0.3,
);

void main() {
  test('defaults: noon at 0.5 and every vital absent', () {
    expect(_base.solarNoon, 0.5);
    expect(_base.sleepScore, isNull);
    expect(_base.recovery, isNull);
    expect(_base.strain, isNull);
    expect(_base.energyBalance, isNull);
    expect(_base.hasVitals, isFalse);
  });

  test('absent vitals resolve to the plain-sky atmosphere', () {
    final s = CelestialScene.resolve(_base);
    // Original defaults: recovery 0.75, strain 0.2, sleep 0.75.
    expect(s.turbidity, closeTo(1.6 + 0.25 * 4.0, 1e-12));
    expect(s.mieScale, closeTo(1.18, 1e-12));
    expect(s.stillness, closeTo(0.35 + 0.75 * 0.65, 1e-12));
  });

  test('sleep drives stillness', () {
    final rested = CelestialScene.resolve(_base.copyWith(sleepScore: 1.0));
    final poor = CelestialScene.resolve(_base.copyWith(sleepScore: 0.0));
    expect(rested.stillness, 1.0);
    expect(poor.stillness, 0.35);
  });

  test('copyWith can clear a vital back to null', () {
    final withSleep = _base.copyWith(sleepScore: 0.8);
    expect(withSleep.hasVitals, isTrue);
    expect(withSleep.copyWith(sleepScore: null).sleepScore, isNull);
  });

  test('lerp takes the short way round midnight and snaps nullable vitals',
      () {
    final a = _base.copyWith(timeOfDay: 0.95);
    final b = _base.copyWith(timeOfDay: 0.05, sleepScore: 0.6);
    final mid = SkyState.lerp(a, b, 0.5);
    expect(mid.timeOfDay, closeTo(0.0, 1e-9));
    expect(mid.sleepScore, 0.6);
    expect(SkyState.lerp(a, b, 0).sleepScore, isNull);
  });

  test('SkyState.at builds from a wall clock', () {
    final s = SkyState.at(DateTime.utc(2026, 6, 21, 12),
        latitudeDeg: 52.23, longitudeDeg: 21.01);
    expect(s.timeOfDay, 0.5);
    expect(s.dayOfYear, 172);
    expect(s.moonPhase, inInclusiveRange(0, 1));
    expect(s.hasVitals, isFalse);
  });
}
