import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_scheduler.dart';
import 'package:illunis_client/alarm/notification_port.dart';
import 'package:illunis_client/app/alarm_coordinator.dart';

import 'alarm_test.dart' show settings;

// The Dart half of the native channel contract. Synthetic values only.

const _kotlin = 'android/app/src/main/kotlin/com/illunis/illunis_client';

final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Records calls on [ch] and answers each with [reply].
List<MethodCall> _mock(MethodChannel ch, [Object? Function(MethodCall)? reply]) {
  final calls = <MethodCall>[];
  _messenger.setMockMethodCallHandler(ch, (c) async {
    calls.add(c);
    return reply?.call(c);
  });
  return calls;
}

/// Sends a native-to-Dart call on [ch] and returns Dart's answer.
Future<Object?> _fromNative(MethodChannel ch, String method, [Object? args]) async {
  Object? answer;
  await _messenger.handlePlatformMessage(ch.name, ch.codec.encodeMethodCall(MethodCall(method, args)),
      (r) => answer = r == null ? null : ch.codec.decodeEnvelope(r));
  return answer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('alarm channel', () {
    test('schedule sends only hour and minute', () async {
      const ch = MethodChannel('test/alarm_schedule');
      final calls = _mock(ch);
      final r = await MethodChannelAlarmScheduler(channel: ch, log: (_) {}).schedule(settings());
      expect(r.ok, isTrue);
      expect(calls.single.method, AlarmChannel.schedule);
      expect(calls.single.arguments, {'hour': settings().hour, 'minute': settings().minute});
    });

    test('disabled settings cancel instead of scheduling', () async {
      const ch = MethodChannel('test/alarm_disabled');
      final calls = _mock(ch);
      await MethodChannelAlarmScheduler(channel: ch, log: (_) {})
          .schedule(settings().copyWith(enabled: false));
      expect(calls.map((c) => c.method), [AlarmChannel.cancel]);
    });

    test('onAlarmFired from native calls onFire', () async {
      const ch = MethodChannel('test/alarm_fired');
      var fired = 0;
      MethodChannelAlarmScheduler(channel: ch, log: (_) {}).onFire = () => fired++;
      await _fromNative(ch, AlarmChannel.onFired);
      expect(fired, 1);
    });

    test('canScheduleExact passes the native answer through', () async {
      const ch = MethodChannel('test/alarm_exact');
      _mock(ch, (_) => false);
      expect(await MethodChannelAlarmScheduler(channel: ch, log: (_) {}).canScheduleExact(), isFalse);
    });

    test('a missing handler logs codes and never throws', () async {
      const ch = MethodChannel('test/alarm_missing');
      final logs = <String>[];
      final s = MethodChannelAlarmScheduler(channel: ch, log: logs.add);
      expect(await s.canScheduleExact(), isTrue);
      expect(await s.openExactAlarmSettings(), isFalse);
      expect((await s.schedule(settings())).code, 'schedule_failed');
      expect(logs, everyElement(startsWith('alarm: ')));
      expect(logs, everyElement(contains('error=MissingPluginException')));
    });
  });

  group('notification channel', () {
    test('show sends title, body and payload id', () async {
      const ch = MethodChannel('test/notify_show');
      final calls = _mock(ch);
      await MethodChannelNotificationPort(channel: ch, log: (_) {})
          .show(title: 'T', body: 'B', payloadId: digestPayloadId);
      expect(calls.single.method, NotificationChannel.show);
      expect(calls.single.arguments, {'title': 'T', 'body': 'B', 'payload_id': digestPayloadId});
    });

    test('cold start: the launch payload is read from native', () async {
      const ch = MethodChannel('test/notify_launch');
      _mock(ch, (c) => c.method == NotificationChannel.launchPayload ? digestPayloadId : null);
      expect(await MethodChannelNotificationPort(channel: ch, log: (_) {}).launchPayload(),
          digestPayloadId);
    });

    test('warm tap reaches onTap and answers true; malformed taps answer false', () async {
      const ch = MethodChannel('test/notify_tap');
      final port = MethodChannelNotificationPort(channel: ch, log: (_) {});
      final taps = <String>[];
      port.onTap.listen(taps.add);
      expect(await _fromNative(ch, NotificationChannel.onTap, {'payload_id': 7}), isFalse);
      expect(await _fromNative(ch, NotificationChannel.onTap, null), isFalse);
      expect(await _fromNative(ch, NotificationChannel.onTap, {'payload_id': digestPayloadId}), isTrue);
      await pumpEventQueue();
      expect(taps, [digestPayloadId]);
    });

    test('a tap before anyone listens answers false, so native keeps it', () async {
      const ch = MethodChannel('test/notify_early');
      MethodChannelNotificationPort(channel: ch, log: (_) {});
      expect(await _fromNative(ch, NotificationChannel.onTap, {'payload_id': digestPayloadId}), isFalse);
    });
  });

  group('Kotlin mirror', () {
    // Run from client/ (flutter test does). Guards strings duplicated in Kotlin.
    String kt(String file) => File('$_kotlin/$file').readAsStringSync();

    test('channel names match the handlers', () {
      expect(kt('AlarmChannelHandler.kt'), contains('CHANNEL = "${AlarmChannel.name}"'));
      expect(kt('NotificationHandler.kt'), contains('CHANNEL = "${NotificationChannel.name}"'));
    });

    test('native digest notification matches the coordinator', () {
      final k = kt('DigestNotifications.kt');
      expect(k, contains('DIGEST_PAYLOAD = "$digestPayloadId"'));
      expect(k, contains('DIGEST_TITLE = "$digestNotificationTitle"'));
      expect(k, contains('DIGEST_BODY = "$digestNotificationBody"'));
    });
  });
}
