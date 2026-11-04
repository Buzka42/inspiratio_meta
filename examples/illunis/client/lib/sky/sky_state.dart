import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';

import 'celestial_math.dart';

/// Everything the sky is allowed to know.
///
/// Ported from the original Illunis app (app/lib/core/sky/sky_state.dart).
/// Left out on purpose: journal path dots and weather (weather needs
/// weather.frag and cloud textures whose licence is unverified).
///
/// The producer of a [SkyState] owns what the numbers *mean*; the sky owns
/// what they *look like*. Nothing here is a health record: every vital is
/// already normalised, and every one of them may be absent.
///
/// Absence is rendered as absence. A `null` recovery is a plain sky, never a
/// bad day.
@immutable
class SkyState {
  const SkyState({
    required this.timeOfDay,
    required this.dayOfYear,
    required this.epochDays,
    required this.latitudeDeg,
    required this.moonPhase,
    this.solarNoon = 0.5,
    this.sleepScore,
    this.recovery,
    this.strain,
    this.energyBalance,
  });

  /// The sky for a local wall-clock [now] at an observer. Real moon phase,
  /// and a solar noon shifted by longitude, zone and the equation of time.
  factory SkyState.at(
    DateTime now, {
    required double latitudeDeg,
    required double longitudeDeg,
    double? sleepScore,
    double? recovery,
    double? strain,
    double? energyBalance,
  }) {
    final t = civilDayFraction(now);
    final midnight = civilMidnightEpoch(now);
    return SkyState(
      timeOfDay: t,
      dayOfYear: civilDayOfYear(now),
      epochDays: midnight,
      latitudeDeg: latitudeDeg,
      moonPhase: moonPhaseFor(now.toUtc()),
      solarNoon: solarNoonFor(
        midnight + t,
        longitudeDeg,
        now.timeZoneOffset.inMinutes / 60.0,
      ),
      sleepScore: sleepScore,
      recovery: recovery,
      strain: strain,
      energyBalance: energyBalance,
    );
  }

  /// Fraction of the local civil day, `0` = midnight, `0.5` = noon.
  final double timeOfDay;

  /// `1..366`, for the almanac line.
  final double dayOfYear;

  /// Days since J2000.0 at this date's local midnight. Drives the Sun's
  /// longitude and every planet. A number, not a `DateTime`, on purpose.
  final double epochDays;

  /// Observer latitude, degrees, north positive.
  final double latitudeDeg;

  /// `0..1` — `0` new, `0.5` full, `1` new again. The moon's position and
  /// its terminator both follow from this and the sun.
  final double moonPhase;

  /// Fraction of the day at which the sun crosses the meridian. `0.5` is
  /// local mean solar time; a real source shifts it by longitude, zone and
  /// the equation of time.
  final double solarNoon;

  /// `0..1`, last night. Drives how still the night is. Null when unknown.
  final double? sleepScore;

  /// `0..1`, readiness this morning. Drives haze. Null when unknown.
  final double? recovery;

  /// `0..1`, accumulated load today. Warms the low sky. Null when unknown.
  final double? strain;

  /// `-1..1`, deficit to surplus over the rolling window. Null when unknown.
  final double? energyBalance;

  bool get hasVitals =>
      sleepScore != null ||
      recovery != null ||
      strain != null ||
      energyBalance != null;

  SkyState copyWith({
    double? timeOfDay,
    double? dayOfYear,
    double? epochDays,
    double? latitudeDeg,
    double? moonPhase,
    double? solarNoon,
    Object? sleepScore = _unset,
    Object? recovery = _unset,
    Object? strain = _unset,
    Object? energyBalance = _unset,
  }) {
    // Moving the day of year moves the epoch with it unless told otherwise.
    final newDay = dayOfYear ?? this.dayOfYear;
    return SkyState(
      timeOfDay: timeOfDay ?? this.timeOfDay,
      dayOfYear: newDay,
      epochDays: epochDays ?? (this.epochDays + (newDay - this.dayOfYear)),
      latitudeDeg: latitudeDeg ?? this.latitudeDeg,
      moonPhase: moonPhase ?? this.moonPhase,
      solarNoon: solarNoon ?? this.solarNoon,
      sleepScore: sleepScore == _unset
          ? this.sleepScore
          : (sleepScore as num?)?.toDouble(),
      recovery: recovery == _unset
          ? this.recovery
          : (recovery as num?)?.toDouble(),
      strain: strain == _unset ? this.strain : (strain as num?)?.toDouble(),
      energyBalance: energyBalance == _unset
          ? this.energyBalance
          : (energyBalance as num?)?.toDouble(),
    );
  }

  /// Interpolation for the view's easing. Angles that wrap (`timeOfDay`,
  /// `moonPhase`) take the short way round so midnight is not a full-day
  /// rewind; a vital that is null on either side snaps rather than fading
  /// through an invented value.
  static SkyState lerp(SkyState a, SkyState b, double t) {
    return SkyState(
      timeOfDay: _lerpWrapped(a.timeOfDay, b.timeOfDay, t),
      dayOfYear: lerpDouble(a.dayOfYear, b.dayOfYear, t)!,
      epochDays: lerpDouble(a.epochDays, b.epochDays, t)!,
      latitudeDeg: lerpDouble(a.latitudeDeg, b.latitudeDeg, t)!,
      moonPhase: _lerpWrapped(a.moonPhase, b.moonPhase, t),
      solarNoon: lerpDouble(a.solarNoon, b.solarNoon, t)!,
      sleepScore: _lerpNullable(a.sleepScore, b.sleepScore, t),
      recovery: _lerpNullable(a.recovery, b.recovery, t),
      strain: _lerpNullable(a.strain, b.strain, t),
      energyBalance: _lerpNullable(a.energyBalance, b.energyBalance, t),
    );
  }

  static double _lerpWrapped(double a, double b, double t) {
    var d = b - a;
    if (d > 0.5) d -= 1;
    if (d < -0.5) d += 1;
    final v = a + d * t;
    return v - v.floorToDouble();
  }

  static double? _lerpNullable(double? a, double? b, double t) {
    if (a == null || b == null) return t <= 0 ? a : b;
    return lerpDouble(a, b, t);
  }

  @override
  bool operator ==(Object other) =>
      other is SkyState &&
      other.timeOfDay == timeOfDay &&
      other.dayOfYear == dayOfYear &&
      other.epochDays == epochDays &&
      other.latitudeDeg == latitudeDeg &&
      other.moonPhase == moonPhase &&
      other.solarNoon == solarNoon &&
      other.sleepScore == sleepScore &&
      other.recovery == recovery &&
      other.strain == strain &&
      other.energyBalance == energyBalance;

  @override
  int get hashCode => Object.hash(
    timeOfDay,
    dayOfYear,
    epochDays,
    latitudeDeg,
    moonPhase,
    solarNoon,
    sleepScore,
    recovery,
    strain,
    energyBalance,
  );

  @override
  String toString() =>
      'SkyState(t=${timeOfDay.toStringAsFixed(4)} d=${dayOfYear.round()} '
      'lat=${latitudeDeg.toStringAsFixed(1)} moon=${moonPhase.toStringAsFixed(3)} '
      'sleep=$sleepScore rec=$recovery strain=$strain energy=$energyBalance)';
}

const _unset = Object();

/// Wall-clock fractions do not gain/lose an hour on DST transition days.
double civilDayFraction(DateTime date) =>
    (date.hour * 3600 +
        date.minute * 60 +
        date.second +
        date.millisecond / 1000) /
    86400;

double civilDayOfYear(DateTime date) =>
    DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).difference(DateTime.utc(date.year)).inDays +
    1.0;

/// Epoch basis using the offset at the represented instant. Adding the
/// wall-clock fraction reconstructs UTC even on a daylight-saving boundary.
double civilMidnightEpoch(DateTime date) =>
    epochDaysForDate(date.year, date.month, date.day) -
    date.timeZoneOffset.inSeconds / 86400.0;
