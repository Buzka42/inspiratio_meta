import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/digest_ticker.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/voice/alarm_digest.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic fixtures only.
const today = LocalDate(2026, 10, 23);
const alarm = LocalTime(7, 0);

MorningFlow flowOn(StateStore store, FakeServerPort server, [SilentTts? tts]) =>
    MorningFlow(tts: tts ?? SilentTts(), server: server, store: store, alarm: alarm);

/// A fresh flow that loads [store], as after an app restart.
Future<MorningFlow> loaded(StateStore store, FakeServerPort server, [SilentTts? tts]) async {
  final f = flowOn(store, server, tts);
  await f.load();
  return f;
}

Future<void> finishInterview(MorningFlow f) async {
  await f.answer(const Acknowledge());
  await f.answer(const ProactiveAnswer(ProactiveMode.proactive));
  await f.answer(const KeywordAnswer('Altair'));
  await f.answer(const PersonalityAnswer('personal_coach', skillPackId: 'habit_building'));
  await f.answer(const ConfirmAnswer(true));
}

class ThrowingStore implements StateStore {
  @override
  Future<bool?> getBool(String key) => throw StateError('disk');
  @override
  Future<void> setBool(String key, bool value) => throw StateError('disk');
  @override
  Future<String?> getString(String key) => throw StateError('disk');
  @override
  Future<void> setString(String key, String value) => throw StateError('disk');
  @override
  Future<void> remove(String key) => throw StateError('disk');
}

/// Manual periodic timer: the test calls [fire] instead of waiting.
class FakeTimer implements Timer {
  FakeTimer(this.onTick);
  final void Function(Timer) onTick;
  bool cancelled = false;
  int ticks = 0;
  void fire() {
    if (cancelled) return;
    ticks++;
    onTick(this);
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => ticks;
}

void main() {
  group('fog', () {
    test('off persists across a restart (shared_preferences)', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppController(
          fog: FogSettings(GuardedStore(SharedPrefsStore())), server: FakeServerPort(), tts: SilentTts());
      await a.load();
      expect(a.fogEnabled, isTrue);
      await a.setFog(false);

      final b = AppController(
          fog: FogSettings(GuardedStore(SharedPrefsStore())), server: FakeServerPort(), tts: SilentTts());
      await b.load();
      expect(b.fogEnabled, isFalse);
      expect((await SharedPreferences.getInstance()).getBool(FogSettings.key), isFalse);
    });
  });

  group('digest', () {
    test('a digest that fired today does not replay after a restart', () async {
      final store = InMemoryStateStore();
      final server = FakeServerPort();
      final a = await loaded(store, server);
      await finishInterview(a);
      expect(await a.tick(now: const LocalTime(7, 0), today: today), isNotNull);

      final b = await loaded(store, server);
      expect(b.lastFired, today);
      expect(b.profile?.personalityId, 'personal_coach');
      expect(await b.tick(now: const LocalTime(7, 5), today: today), isNull);
      expect(server.digestCalls, hasLength(1));
      // The next morning fires again.
      expect(await b.tick(now: const LocalTime(7, 0), today: const LocalDate(2026, 10, 24)), isNotNull);
      expect(server.digestCalls, hasLength(2));
    });

    test('also survives a restart on shared_preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final server = FakeServerPort();
      final a = await loaded(GuardedStore(SharedPrefsStore()), server);
      await finishInterview(a);
      await a.tick(now: const LocalTime(7, 1), today: today);
      final b = await loaded(GuardedStore(SharedPrefsStore()), server);
      expect(await b.tick(now: const LocalTime(7, 2), today: today), isNull);
      expect(server.digestCalls, hasLength(1));
    });

    test('catch-up window still works after a restart', () async {
      final store = InMemoryStateStore();
      final server = FakeServerPort();
      await finishInterview(await loaded(store, server));

      // App was closed through the alarm; opened 150 minutes later.
      final b = await loaded(store, server);
      expect(await b.tick(now: const LocalTime(9, 30), today: today), isNotNull);

      // Opened after the window on another day: skipped as stale.
      final c = await loaded(store, server);
      expect(await c.tick(now: const LocalTime(10, 1), today: const LocalDate(2026, 10, 24)), isNull);
      expect(server.digestCalls, hasLength(1));
    });
  });

  group('interview', () {
    test('resumes at the same step with earlier answers after a restart', () async {
      final store = InMemoryStateStore();
      final a = await loaded(store, FakeServerPort());
      await a.answer(const Acknowledge());
      await a.answer(const ProactiveAnswer(ProactiveMode.proactive));
      await a.answer(const KeywordAnswer('Altair'));
      expect(a.interview.step, InterviewStep.askDigestPersonality);

      final tts = SilentTts();
      final b = await loaded(store, FakeServerPort(), tts);
      expect(b.interview.step, InterviewStep.askDigestPersonality);
      expect(b.interview.proactive, isTrue);
      expect(b.interview.keyword?.word, 'altair');
      expect(b.profile, isNull);
      await b.start();
      expect(tts.spoken.single, startsWith('Each morning at your alarm'));

      await b.answer(const PersonalityAnswer('socratic_tutor'));
      await b.answer(const ConfirmAnswer(true));
      expect(b.profile?.keyword, 'altair');
      expect(b.profile?.proactive, isTrue);
    });

    test('malformed or inconsistent saved state starts over', () async {
      final store = InMemoryStateStore();
      for (final raw in ['not json', '[]', '{"step":"nope"}', '{"step":"confirm","keyword":"altair"}']) {
        await store.setString(StoreKeys.interview, raw);
        final f = await loaded(store, FakeServerPort());
        expect(f.interview.step, InterviewStep.greet, reason: raw);
      }
    });

    test('date codec round-trips and rejects junk', () {
      expect(decodeDate(encodeDate(const LocalDate(2026, 1, 5))), const LocalDate(2026, 1, 5));
      expect(encodeDate(const LocalDate(2026, 1, 5)), '2026-01-05');
      expect(decodeDate('2026-13-01'), isNull);
      expect(decodeDate('yesterday'), isNull);
      expect(decodeDate(null), isNull);
    });
  });

  group('ticker', () {
    test('fires once per day with a fake clock, then cancels on dispose', () async {
      final store = InMemoryStateStore();
      final server = FakeServerPort();
      final flow = await loaded(store, server);
      await finishInterview(flow);

      var now = DateTime(2026, 10, 23, 6, 55);
      FakeTimer? timer;
      Duration? period;
      final ticker = DigestTicker(
        flow: flow,
        clock: () => now,
        timer: (p, cb) {
          period = p;
          return timer = FakeTimer(cb);
        },
      )..start();
      expect(period, const Duration(minutes: 1));

      // Two days, minute by minute.
      for (var i = 0; i < 2 * 24 * 60; i++) {
        now = now.add(const Duration(minutes: 1));
        timer!.fire();
        await pumpEventQueue(times: 2);
      }
      expect(server.digestCalls, hasLength(2));
      expect(flow.lastFired, const LocalDate(2026, 10, 24));

      ticker.dispose();
      expect(timer!.cancelled, isTrue);
      expect(ticker.running, isFalse);
      now = DateTime(2026, 10, 25, 7, 0);
      timer!.fire(); // Cancelled: no effect.
      await pumpEventQueue();
      expect(server.digestCalls, hasLength(2));
    });

    test('a ticker on a restarted app does not replay today\'s digest', () async {
      final store = InMemoryStateStore();
      final server = FakeServerPort();
      final a = await loaded(store, server);
      await finishInterview(a);
      await a.tick(now: const LocalTime(7, 0), today: today);

      final b = await loaded(store, server);
      final ticker = DigestTicker(
          flow: b, clock: () => DateTime(2026, 10, 23, 7, 30), timer: (p, cb) => FakeTimer(cb))
        ..start(); // start() checks once at open.
      await pumpEventQueue();
      expect(await ticker.check(), isNull);
      expect(server.digestCalls, hasLength(1));
      ticker.dispose();
    });

    test('a throwing digest call is logged without payload and retried', () async {
      final server = _FailingOnce();
      final flow = await loaded(InMemoryStateStore(), server);
      await finishInterview(flow);
      final logs = <String>[];
      final ticker = DigestTicker(
          flow: flow, clock: () => DateTime(2026, 10, 23, 7, 1), timer: (p, cb) => FakeTimer(cb), log: logs.add);
      expect(await ticker.check(), isNull);
      expect(logs.single, 'digest: tick failed error=ServerException');
      expect(await ticker.check(), isNotNull);
    });
  });

  group('failing store', () {
    test('app and flow keep working on defaults and logs carry no values', () async {
      final logs = <String>[];
      final store = GuardedStore(ThrowingStore(), log: logs.add);
      final c = AppController(fog: FogSettings(store), server: FakeServerPort(), tts: SilentTts());
      await c.load();
      expect(c.fogEnabled, isTrue);
      await c.setFog(false);
      expect(c.fogEnabled, isFalse); // Holds for this session.

      final server = FakeServerPort();
      final f = await loaded(store, server);
      expect(f.interview.step, InterviewStep.greet);
      await finishInterview(f);
      expect(await f.tick(now: const LocalTime(7, 0), today: today), isNotNull);
      expect(await f.tick(now: const LocalTime(7, 1), today: today), isNull); // In-memory guard.

      expect(logs, isNotEmpty);
      for (final l in logs) {
        expect(l, matches(RegExp(r'^persistence: (read|write|remove) failed key=\w+ error=StateError$')));
        expect(l, isNot(contains('altair')));
        expect(l, isNot(contains('2026')));
        expect(l, isNot(contains('false')));
      }
    });

    test('a shared_preferences open failure falls back and is retried', () async {
      SharedPreferences.setMockInitialValues({FogSettings.key: false});
      var fail = true;
      final logs = <String>[];
      final store = GuardedStore(
          SharedPrefsStore(open: () => fail ? Future.error(StateError('open')) : SharedPreferences.getInstance()),
          log: logs.add);
      final fog = FogSettings(store);
      await fog.load();
      expect(fog.enabled, isTrue);
      expect(logs.single, 'persistence: read failed key=fog_enabled error=StateError');
      fail = false;
      await fog.load();
      expect(fog.enabled, isFalse);
    });
  });
}

class _FailingOnce extends FakeServerPort {
  bool failed = false;
  @override
  Future<DigestResult> digest({
    required String personalityId,
    required List<Finding> findings,
    String? skillPackId,
    CouncilContext? context,
    bool council = true,
  }) async {
    if (!failed) {
      failed = true;
      throw const ServerException(502, 'upstream_error');
    }
    return super.digest(personalityId: personalityId, findings: findings, skillPackId: skillPackId);
  }
}
