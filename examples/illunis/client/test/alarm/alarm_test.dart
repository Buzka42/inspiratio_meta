import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_scheduler.dart';
import 'package:illunis_client/alarm/alarm_settings.dart';
import 'package:illunis_client/alarm/notification_port.dart';
import 'package:illunis_client/app/alarm_coordinator.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Synthetic fixtures only.

/// Records speech and voice-state changes in one ordered list.
class OrderedTts implements TtsPort {
  OrderedTts(this.events);
  final List<String> events;
  @override
  Future<void> speak(String text) async => events.add('speak:$text');
  @override
  Future<void> stop() async {}
}

AlarmSettings settings({int hour = 7, int minute = 0, bool enabled = true, AlarmLog? log}) =>
    AlarmSettings.validate(
        hour: hour,
        minute: minute,
        enabled: enabled,
        personalityId: 'productivity_advisor',
        skillPackId: 'habit_building',
        log: log ?? (_) {})!;

class Rig {
  Rig({DateTime? now, String? launchedWith, StateStore? store}) {
    this.store = store ?? InMemoryStateStore();
    tts = OrderedTts(events);
    controller = AppController(fog: FogSettings(this.store), server: server, tts: tts);
    controller.addListener(() => events.add('voice:${controller.voice.name}'));
    flow = MorningFlow(tts: tts, server: server, store: this.store);
    notifications = FakeNotificationPort(launchedWith: launchedWith);
    coordinator = AlarmCoordinator(
      settingsStore: AlarmSettingsStore(this.store, log: logs.add),
      scheduler: scheduler,
      notifications: notifications,
      flow: flow,
      controller: controller,
      clock: () => now ?? DateTime(2026, 10, 23, 7, 0),
      log: logs.add,
    );
  }

  final events = <String>[];
  final logs = <String>[];
  late final StateStore store;
  final server = FakeServerPort(digestResult: const DigestResult(text: 'Synthetic digest.'));
  late final OrderedTts tts;
  late final AppController controller;
  late final MorningFlow flow;
  final scheduler = FakeAlarmScheduler();
  late final FakeNotificationPort notifications;
  late final AlarmCoordinator coordinator;

  Future<void> interview() async {
    await flow.answer(const Acknowledge());
    await flow.answer(const ProactiveAnswer(ProactiveMode.wait));
    await flow.answer(const KeywordAnswer('Altair'));
    await flow.answer(const PersonalityAnswer('calm_guide'));
    await flow.answer(const ConfirmAnswer(true));
    events.clear();
  }
}

void main() {
  group('validation', () {
    test('accepts the edges of the range', () {
      expect(settings(hour: 0, minute: 0).time.minutesOfDay, 0);
      expect(settings(hour: 23, minute: 59).time.minutesOfDay, 23 * 60 + 59);
    });

    test('rejects hours and minutes out of range with a code', () {
      for (final (h, m) in [(-1, 0), (24, 0), (7, -1), (7, 60)]) {
        final logs = <String>[];
        expect(AlarmSettings.validate(hour: h, minute: m, log: logs.add), isNull);
        expect(logs, ['alarm: invalid_time']);
      }
    });

    test('unknown personality falls back to the default and logs only a code', () {
      final logs = <String>[];
      final s = AlarmSettings.validate(
          hour: 7, minute: 0, personalityId: 'synthetic_unknown', log: logs.add)!;
      expect(s.personalityId, defaultPersonalityId);
      expect(logs, ['alarm: unknown_personality']);
      expect(logs.join(), isNot(contains('synthetic_unknown')));
    });

    test('unknown skill pack is dropped with a code', () {
      final logs = <String>[];
      final s = AlarmSettings.validate(
          hour: 7, minute: 0, personalityId: 'calm_guide', skillPackId: 'nope', log: logs.add)!;
      expect(s.skillPackId, isNull);
      expect(logs, ['alarm: unknown_skill_pack']);
    });
  });

  group('persistence', () {
    test('round-trips through the guarded store', () async {
      final store = GuardedStore(InMemoryStateStore(), log: (_) {});
      final s = settings(hour: 6, minute: 45);
      await AlarmSettingsStore(store).save(s);
      expect(await AlarmSettingsStore(store).load(), s);
      final off = s.copyWith(enabled: false);
      await AlarmSettingsStore(store).save(off);
      expect(await AlarmSettingsStore(store).load(), off);
    });

    test('nothing saved loads as null', () async {
      expect(await AlarmSettingsStore(InMemoryStateStore()).load(), isNull);
    });

    test('bad saved values are ignored, not thrown', () async {
      for (final raw in [
        'not json',
        '[1,2]',
        '{"hour":"7","minute":0,"enabled":true}',
        '{"hour":25,"minute":0,"enabled":true,"personality_id":"calm_guide"}',
        '{"hour":7,"minute":0}',
      ]) {
        final store = InMemoryStateStore();
        await store.setString(alarmSettingsKey, raw);
        final logs = <String>[];
        expect(await AlarmSettingsStore(store, log: logs.add).load(), isNull, reason: raw);
        expect(logs, hasLength(1));
        expect(logs.single, startsWith('alarm: '));
      }
    });

    test('a bad saved alarm does not crash start and schedules nothing', () async {
      final store = InMemoryStateStore();
      await store.setString(alarmSettingsKey, '{"hour":99');
      final r = Rig(store: store);
      await r.coordinator.start();
      expect(r.coordinator.settings, isNull);
      expect(r.scheduler.scheduled, isNull);
      expect(r.flow.alarm, isNull);
      expect(r.logs, contains('alarm: bad_saved_settings'));
    });
  });

  group('fire and tap', () {
    test('scheduler fires, notification shows, tap plays digest then listens', () async {
      final r = Rig();
      await r.interview();
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings());
      expect(r.scheduler.scheduled, settings());
      expect(r.flow.alarm!.minutesOfDay, 7 * 60);

      r.scheduler.fire();
      await pumpEventQueue();
      expect(r.notifications.shown, hasLength(1));
      expect(r.notifications.shown.single.payloadId, digestPayloadId);
      expect(r.events, isEmpty, reason: 'the alarm itself never starts listening');

      r.notifications.tap(digestPayloadId);
      await pumpEventQueue();
      expect(r.events, ['speak:Synthetic digest.', 'voice:listening']);
      expect(r.controller.voice, VoiceState.listening);
      expect(r.server.digestCalls.single.personalityId, 'productivity_advisor');
      expect(r.server.digestCalls.single.skillPackId, 'habit_building');
    });

    test('a tap that launched the app is handled at start', () async {
      final store = InMemoryStateStore();
      final first = Rig(store: store);
      await first.interview();
      await first.coordinator.setAlarm(settings());

      final r = Rig(store: store, launchedWith: digestPayloadId);
      await r.flow.load();
      await r.coordinator.start();
      expect(r.events, ['speak:Synthetic digest.', 'voice:listening']);
    });

    test('second tap the same day only listens; no digest replay', () async {
      final r = Rig();
      await r.interview();
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings());
      await r.coordinator.handleTap(digestPayloadId);
      r.controller.dispatch(const UserSpeechEnded('')); // back to idle
      r.events.clear();
      await r.coordinator.handleTap(digestPayloadId);
      expect(r.events, ['voice:listening']);
      expect(r.server.digestCalls, hasLength(1));
    });

    test('unknown payload is ignored', () async {
      final r = Rig();
      await r.interview();
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings());
      r.notifications.tap('other');
      await pumpEventQueue();
      expect(r.events, isEmpty);
      expect(r.logs, contains('alarm: unknown_payload'));
    });
  });

  group('cancel', () {
    test('cancel stops the alarm, persists disabled and ignores later fires', () async {
      final r = Rig();
      await r.interview();
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings());
      final fire = r.scheduler.onFire!;
      await r.coordinator.cancel();
      expect(r.scheduler.scheduled, isNull);
      expect(r.scheduler.cancels, 1);
      expect(r.flow.alarm, isNull);
      expect((await AlarmSettingsStore(r.store).load())!.enabled, isFalse);

      fire(); // a stale platform fire after cancel
      await pumpEventQueue();
      expect(r.notifications.shown, isEmpty);
    });

    test('saving a disabled alarm cancels instead of scheduling', () async {
      final r = Rig();
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings(enabled: false));
      expect(r.scheduler.scheduled, isNull);
      expect(r.scheduler.cancels, 1);
      expect(r.flow.alarm, isNull);
    });
  });
}
