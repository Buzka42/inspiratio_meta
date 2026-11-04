/// Health Connect on MethodChannel `illunis/health`, served by
/// HealthChannel.kt. Reads sleep sessions, steps and heart rate as daily
/// signals for the last 21 days. Not run on a device yet.
///
/// Methods (all answers are plain codes or numbers, never record payloads):
///  - `availability`      -> "available" | "not_installed" | "update_required" | "unsupported"
///  - `hasPermissions`    -> bool (all three read permissions granted)
///  - `requestPermissions`-> "granted" | "partial" | "denied" (opens the system sheet)
///  - `readDaily` {days}  -> {tz, days: [{day, sleep_minutes, steps, resting_hr}]}
/// Errors: `not_available`, `not_granted`, `busy`, `read_failed`, `internal`.
library;

import 'package:flutter/services.dart';

import 'daily_signals.dart';

const healthChannelName = 'illunis/health';
const healthDays = 21;

enum HealthAvailability { available, notInstalled, updateRequired, unsupported }

enum HealthPermission { granted, partial, denied, unavailable }

/// The days read and the phone's time zone (an IANA id such as Europe/Warsaw).
class HealthRead {
  const HealthRead({required this.tz, required this.days});
  final String tz;
  final List<DailySignals> days;
}

/// A failed read; [code] is one of the channel's fixed codes.
class HealthException implements Exception {
  const HealthException(this.code);
  final String code;
  @override
  String toString() => 'HealthException($code)';
}

abstract class HealthPort {
  Future<HealthAvailability> availability();
  Future<bool> hasPermissions();

  /// Shows the Health Connect permission sheet when something is missing.
  Future<HealthPermission> requestPermissions();

  /// Daily signals for the last [days] local days, oldest first. Fails with
  /// [HealthException].
  Future<HealthRead> readDaily({int days = healthDays});
}

class ChannelHealthPort implements HealthPort {
  ChannelHealthPort({MethodChannel? channel}) : _ch = channel ?? const MethodChannel(healthChannelName);
  final MethodChannel _ch;

  @override
  Future<HealthAvailability> availability() async {
    try {
      return switch (await _ch.invokeMethod<String>('availability')) {
        'available' => HealthAvailability.available,
        'not_installed' => HealthAvailability.notInstalled,
        'update_required' => HealthAvailability.updateRequired,
        _ => HealthAvailability.unsupported,
      };
    } on MissingPluginException {
      return HealthAvailability.unsupported;
    } on PlatformException {
      return HealthAvailability.unsupported;
    }
  }

  @override
  Future<bool> hasPermissions() async {
    try {
      return await _ch.invokeMethod<bool>('hasPermissions') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<HealthPermission> requestPermissions() async {
    try {
      return switch (await _ch.invokeMethod<String>('requestPermissions')) {
        'granted' => HealthPermission.granted,
        'partial' => HealthPermission.partial,
        _ => HealthPermission.denied,
      };
    } on MissingPluginException {
      return HealthPermission.unavailable;
    } on PlatformException {
      return HealthPermission.unavailable;
    }
  }

  @override
  Future<HealthRead> readDaily({int days = healthDays}) async {
    final Object? r;
    try {
      r = await _ch.invokeMethod<Object?>('readDaily', {'days': days});
    } on MissingPluginException {
      throw const HealthException('not_available');
    } on PlatformException catch (e) {
      throw HealthException(RegExp(r'^[a-z_]{1,40}$').hasMatch(e.code) ? e.code : 'internal');
    }
    return parseHealthRead(r);
  }
}

/// The `readDaily` answer, with bad entries dropped and days sorted. A
/// missing or malformed answer fails with code `read_failed`.
HealthRead parseHealthRead(Object? r) {
  if (r is! Map || r['days'] is! List) throw const HealthException('read_failed');
  final tz = r['tz'];
  final days = [for (final d in r['days'] as List) ?DailySignals.fromJson(d)]
    ..sort((a, b) => a.day.compareTo(b.day));
  return HealthRead(tz: tz is String && tz.isNotEmpty ? tz : 'UTC', days: days);
}

/// Offline and test stand-in with synthetic data only.
class FakeHealthPort implements HealthPort {
  FakeHealthPort({
    this.available = HealthAvailability.available,
    this.granted = false,
    this.grantOnRequest = HealthPermission.granted,
    this.tz = 'Europe/Warsaw',
    List<DailySignals>? days,
  }) : days = days ?? [];

  HealthAvailability available;
  bool granted;
  HealthPermission grantOnRequest;
  String tz;
  List<DailySignals> days;
  HealthException? readError;
  int permissionRequests = 0;
  final readCalls = <int>[];

  @override
  Future<HealthAvailability> availability() async => available;

  @override
  Future<bool> hasPermissions() async => granted;

  @override
  Future<HealthPermission> requestPermissions() async {
    permissionRequests++;
    if (available != HealthAvailability.available) return HealthPermission.unavailable;
    granted = grantOnRequest == HealthPermission.granted;
    return grantOnRequest;
  }

  @override
  Future<HealthRead> readDaily({int days = healthDays}) async {
    readCalls.add(days);
    final e = readError;
    if (e != null) throw e;
    if (!granted) throw const HealthException('not_granted');
    final list = this.days;
    return HealthRead(tz: tz, days: list.length <= days ? List.of(list) : list.sublist(list.length - days));
  }
}
