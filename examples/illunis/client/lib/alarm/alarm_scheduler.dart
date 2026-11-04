/// Schedules the daily alarm. On Android 14+ a microphone foreground service
/// cannot start from an alarm receiver with the screen off, so the alarm only
/// posts a notification (see notification_port.dart); the user's tap starts
/// listening.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'alarm_settings.dart';

/// Outcome of [AlarmScheduler.schedule]. [code] is a short error code from
/// the platform (for example `exact_alarm_denied`), never user text.
class ScheduleResult {
  const ScheduleResult.ok() : code = null;
  const ScheduleResult.failed(String this.code);

  final String? code;
  bool get ok => code == null;
}

const exactAlarmDeniedCode = 'exact_alarm_denied';

abstract class AlarmScheduler {
  /// Called when the alarm goes off. Set by the coordinator.
  VoidCallback? onFire;

  /// Replaces any scheduled alarm. Disabled settings cancel instead.
  /// Never throws; a refusal comes back as a failed [ScheduleResult].
  Future<ScheduleResult> schedule(AlarmSettings settings);

  Future<void> cancel();

  /// False when Android 12+ exact-alarm access is off (new installs on
  /// Android 14+ start that way). True on older Android.
  Future<bool> canScheduleExact();

  /// Opens Settings > Alarms & reminders (or the app details screen).
  /// Only call this from a user action. Returns false when nothing opened.
  Future<bool> openExactAlarmSettings();
}

/// In-memory scheduler for tests. [fire] simulates the alarm going off.
class FakeAlarmScheduler implements AlarmScheduler {
  @override
  VoidCallback? onFire;

  AlarmSettings? scheduled;
  int cancels = 0;

  /// Simulates the exact-alarm grant. While false, [schedule] is refused
  /// with `exact_alarm_denied`, like the native side.
  bool exactAllowed = true;
  int settingsOpened = 0;

  @override
  Future<ScheduleResult> schedule(AlarmSettings settings) async {
    if (!settings.enabled) {
      await cancel();
      return const ScheduleResult.ok();
    }
    if (!exactAllowed) return const ScheduleResult.failed(exactAlarmDeniedCode);
    scheduled = settings;
    return const ScheduleResult.ok();
  }

  @override
  Future<bool> canScheduleExact() async => exactAllowed;

  @override
  Future<bool> openExactAlarmSettings() async {
    settingsOpened++;
    return true;
  }

  @override
  Future<void> cancel() async {
    scheduled = null;
    cancels++;
  }

  /// Fires only while an alarm is scheduled, like the platform would.
  void fire() {
    if (scheduled != null) onFire?.call();
  }
}

/// Platform contract for the native side (AlarmChannelHandler.kt).
abstract final class AlarmChannel {
  static const name = 'illunis/alarm';

  /// Dart to native: `{hour: int, minute: int}`, local wall clock, repeats
  /// daily. Native should use AlarmManager.setAlarmClock (or exact alarms with
  /// SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM) and reschedule after boot.
  static const schedule = 'schedule';

  /// Dart to native: no arguments.
  static const cancel = 'cancel';

  /// Dart to native: no arguments, returns bool.
  static const canScheduleExact = 'canScheduleExact';

  /// Dart to native: no arguments, returns bool (true when a screen opened).
  /// ACTION_REQUEST_SCHEDULE_EXACT_ALARM on Android 12+, else app details.
  static const openExactAlarmSettings = 'openExactAlarmSettings';

  /// Native to Dart: no arguments, sent when the alarm fires while the
  /// Flutter engine is running. When it is not, native posts the digest
  /// notification itself with [NotificationChannel] payload `morning_digest`.
  static const onFired = 'onAlarmFired';
}

/// Talks to AlarmChannelHandler.kt. A denied schedule for a new time opens
/// Settings > Alarms & reminders natively. Without the handler every call
/// fails with MissingPluginException, which becomes a failed result.
class MethodChannelAlarmScheduler implements AlarmScheduler {
  MethodChannelAlarmScheduler({MethodChannel? channel, AlarmLog? log})
      : _ch = channel ?? const MethodChannel(AlarmChannel.name),
        _log = log ?? debugPrint {
    _ch.setMethodCallHandler((call) async {
      if (call.method == AlarmChannel.onFired) onFire?.call();
    });
  }

  final MethodChannel _ch;
  final AlarmLog _log;

  @override
  VoidCallback? onFire;

  @override
  Future<ScheduleResult> schedule(AlarmSettings settings) async {
    if (!settings.enabled) {
      await cancel();
      return const ScheduleResult.ok();
    }
    try {
      await _ch.invokeMethod<void>(
          AlarmChannel.schedule, {'hour': settings.hour, 'minute': settings.minute});
      return const ScheduleResult.ok();
    } on PlatformException catch (e) {
      return ScheduleResult.failed(e.code);
    } catch (e) {
      _log('alarm: schedule_failed error=${e.runtimeType}');
      return const ScheduleResult.failed('schedule_failed');
    }
  }

  @override
  Future<bool> canScheduleExact() async {
    try {
      return await _ch.invokeMethod<bool>(AlarmChannel.canScheduleExact) ?? false;
    } catch (e) {
      // Unknown: assume granted so no prompt shows for a missing channel.
      _log('alarm: can_schedule_exact_failed error=${e.runtimeType}');
      return true;
    }
  }

  @override
  Future<bool> openExactAlarmSettings() async {
    try {
      return await _ch.invokeMethod<bool>(AlarmChannel.openExactAlarmSettings) ?? false;
    } catch (e) {
      _log('alarm: open_settings_failed error=${e.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _ch.invokeMethod<void>(AlarmChannel.cancel);
    } catch (e) {
      _log('alarm: cancel_failed error=${e.runtimeType}');
    }
  }
}
