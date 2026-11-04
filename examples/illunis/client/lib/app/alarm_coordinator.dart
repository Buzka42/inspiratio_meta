/// Alarm to notification to tap to digest to listening.
///
/// The alarm never opens the microphone itself: on Android 14+ a mic
/// foreground service cannot start from an alarm receiver with the screen
/// off. The alarm posts a notification; the tap opens the app, plays the
/// digest through [MorningFlow], then starts listening through
/// [AppController] (the wake-word path).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../alarm/alarm_scheduler.dart';
import '../alarm/alarm_settings.dart';
import '../alarm/notification_port.dart';
import '../voice/alarm_digest.dart';
import '../voice/voice_session.dart';
import 'app_controller.dart';
import 'digest_ticker.dart';
import 'morning_flow.dart';
import 'server_port.dart';

const digestPayloadId = 'morning_digest';
const digestNotificationTitle = 'Good morning';
const digestNotificationBody = 'Tap to hear your morning digest.';

class AlarmCoordinator {
  AlarmCoordinator({
    required this.settingsStore,
    required this.scheduler,
    required this.notifications,
    required this.flow,
    required this.controller,
    Clock? clock,
    this.findings,
    AlarmLog? log,
  })  : _clock = clock ?? DateTime.now,
        _log = log ?? debugPrint {
    // One voice: the digest plays through the controller's speech, so a
    // barge-in (or a reply) cancels it.
    flow.speech = controller.speech;
  }

  final AlarmSettingsStore settingsStore;
  final AlarmScheduler scheduler;
  final NotificationPort notifications;
  final MorningFlow flow;
  final AppController controller;
  final List<Finding> Function()? findings;
  final Clock _clock;
  final AlarmLog _log;

  AlarmSettings? _settings;
  AlarmSettings? get settings => _settings;
  StreamSubscription<String>? _tapSub;
  bool _handlingTap = false;

  bool _needsExactAlarmGrant = false;

  /// True when Android exact-alarm access is off, so the alarm cannot be
  /// set. The UI shows ExactAlarmNotice (lib/alarm/) while this is true.
  bool get needsExactAlarmGrant => _needsExactAlarmGrant;

  /// Error code of the last refused schedule (for example
  /// `exact_alarm_denied`), or null when the last one was accepted.
  String? get lastScheduleError => _lastScheduleError;
  String? _lastScheduleError;

  /// Loads saved settings (a bad save is ignored), schedules them, wires the
  /// fire and tap paths, and handles a tap that launched the app.
  /// Call after [MorningFlow.load] so the interview profile exists.
  Future<void> start() async {
    scheduler.onFire = () => unawaited(_onFire());
    _tapSub = notifications.onTap.listen((p) => unawaited(handleTap(p)));
    final saved = await settingsStore.load();
    if (saved != null) await _apply(saved);
    await refreshExactAlarmGrant();
    final launch = await notifications.launchPayload();
    if (launch != null) await handleTap(launch);
  }

  /// Saves and schedules [s]. Settings are set by code for now (no UI).
  Future<void> setAlarm(AlarmSettings s) async {
    await settingsStore.save(s);
    await _apply(s);
  }

  /// Turns the alarm off, keeping the time and personality for later.
  Future<void> cancel() async {
    final s = _settings;
    if (s != null) await settingsStore.save(s.copyWith(enabled: false));
    _settings = s?.copyWith(enabled: false);
    flow.alarm = null;
    await scheduler.cancel();
  }

  Future<void> _apply(AlarmSettings s) async {
    _settings = s;
    flow.alarm = s.enabled ? s.time : null;
    // The alarm's personality and skill pack program the digest. Before the
    // interview is done there is no profile, so no digest plays yet.
    final p = flow.profile;
    if (p != null) {
      flow.profile = DigestProfile(
          proactive: p.proactive,
          keyword: p.keyword,
          personalityId: s.personalityId,
          skillPackId: s.skillPackId);
    }
    if (s.enabled) {
      final r = await scheduler.schedule(s);
      _lastScheduleError = r.code;
      if (!r.ok) _log('alarm: not_scheduled code=${r.code}');
      if (r.ok) _needsExactAlarmGrant = false;
      if (r.code == exactAlarmDeniedCode) _needsExactAlarmGrant = true;
    } else {
      _lastScheduleError = null;
      await scheduler.cancel();
    }
  }

  /// Re-reads the exact-alarm grant. Call when the app resumes (the user may
  /// be back from Settings); a new grant schedules the saved alarm.
  Future<void> refreshExactAlarmGrant() async {
    final was = _needsExactAlarmGrant;
    _needsExactAlarmGrant = !await scheduler.canScheduleExact();
    final s = _settings;
    if (was && !_needsExactAlarmGrant && s != null && s.enabled) await _apply(s);
  }

  /// Opens the exact-alarm settings screen. Wire it to the notice's button
  /// only; never call it without a user action.
  Future<void> openExactAlarmSettings() async {
    if (!await scheduler.openExactAlarmSettings()) _log('alarm: settings_not_opened');
  }

  Future<void> _onFire() async {
    if (_settings?.enabled != true) return;
    try {
      await notifications.show(
          title: digestNotificationTitle, body: digestNotificationBody, payloadId: digestPayloadId);
    } catch (e) {
      _log('alarm: notify_failed error=${e.runtimeType}');
    }
  }

  /// Plays the digest (when [MorningFlow] allows it: alarm set, profile
  /// ready, within the catch-up window, not already played today), then
  /// starts listening. Other payload ids are ignored.
  Future<void> handleTap(String payloadId) async {
    if (payloadId != digestPayloadId) {
      _log('alarm: unknown_payload');
      return;
    }
    if (_handlingTap) return;
    _handlingTap = true;
    try {
      final now = _clock();
      await flow.tick(
        now: LocalTime(now.hour, now.minute),
        today: LocalDate(now.year, now.month, now.day),
        findings: findings?.call() ?? const [],
      );
    } catch (e) {
      _log('alarm: digest_failed error=${e.runtimeType}');
    } finally {
      _handlingTap = false;
    }
    controller.dispatch(const WakeWordHeard());
  }

  Future<void> dispose() async {
    scheduler.onFire = null;
    await _tapSub?.cancel();
  }
}
