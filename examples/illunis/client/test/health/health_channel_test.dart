import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/health/daily_signals.dart';
import 'package:illunis_client/health/health_port.dart';

// The Dart half of the `illunis/health` channel, against a mock native side,
// plus a check that the Kotlin and manifest halves name the same contract.
// Synthetic values only.

const _kotlin = 'android/app/src/main/kotlin/com/illunis/illunis_client';
final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

List<MethodCall> _mock(MethodChannel ch, Object? Function(MethodCall) reply) {
  final calls = <MethodCall>[];
  _messenger.setMockMethodCallHandler(ch, (c) async {
    calls.add(c);
    return reply(c);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChannelHealthPort', () {
    test('availability codes map to the enum; anything else is unsupported', () async {
      const ch = MethodChannel('test/health_avail');
      for (final (code, want) in [
        ('available', HealthAvailability.available),
        ('not_installed', HealthAvailability.notInstalled),
        ('update_required', HealthAvailability.updateRequired),
        ('something_new', HealthAvailability.unsupported),
      ]) {
        _mock(ch, (_) => code);
        expect(await ChannelHealthPort(channel: ch).availability(), want);
      }
    });

    test('no native side (MissingPlugin) is unsupported / unavailable, never a crash', () async {
      final p = ChannelHealthPort(channel: const MethodChannel('test/health_none'));
      expect(await p.availability(), HealthAvailability.unsupported);
      expect(await p.hasPermissions(), isFalse);
      expect(await p.requestPermissions(), HealthPermission.unavailable);
      await expectLater(p.readDaily(), throwsA(isA<HealthException>().having((e) => e.code, 'code', 'not_available')));
    });

    test('requestPermissions maps granted, partial and denied', () async {
      const ch = MethodChannel('test/health_perm');
      for (final (code, want) in [
        ('granted', HealthPermission.granted),
        ('partial', HealthPermission.partial),
        ('denied', HealthPermission.denied),
      ]) {
        final calls = _mock(ch, (_) => code);
        expect(await ChannelHealthPort(channel: ch).requestPermissions(), want);
        expect(calls.single.method, 'requestPermissions');
      }
    });

    test('readDaily sends {days} and parses days oldest first, dropping bad entries', () async {
      const ch = MethodChannel('test/health_read');
      final calls = _mock(ch, (_) => {
            'tz': 'Europe/Warsaw',
            'days': [
              {'day': '2026-10-24', 'sleep_minutes': 420, 'steps': 8000, 'resting_hr': 55},
              {'day': '2026-10-23', 'sleep_minutes': null, 'steps': 5000, 'resting_hr': null},
              {'day': 'yesterday', 'steps': 1},
              {'day': '2026-10-25', 'sleep_minutes': 5000, 'steps': -3, 'resting_hr': 400},
            ],
          });
      final r = await ChannelHealthPort(channel: ch).readDaily();
      expect(calls.single.arguments, {'days': 21});
      expect(r.tz, 'Europe/Warsaw');
      expect(r.days, const [
        DailySignals(day: '2026-10-23', steps: 5000),
        DailySignals(day: '2026-10-24', sleepMinutes: 420, steps: 8000, restingHr: 55),
        DailySignals(day: '2026-10-25'), // Out-of-range values become null.
      ]);
    });

    test('a native error keeps its fixed code; odd codes become internal', () async {
      const ch = MethodChannel('test/health_err');
      _mock(ch, (_) => throw PlatformException(code: 'not_granted'));
      await expectLater(ChannelHealthPort(channel: ch).readDaily(),
          throwsA(isA<HealthException>().having((e) => e.code, 'code', 'not_granted')));
      _mock(ch, (_) => throw PlatformException(code: 'Weird Code 42'));
      await expectLater(ChannelHealthPort(channel: ch).readDaily(),
          throwsA(isA<HealthException>().having((e) => e.code, 'code', 'internal')));
      _mock(ch, (_) => 'not a map');
      await expectLater(ChannelHealthPort(channel: ch).readDaily(), throwsA(isA<HealthException>()));
    });
  });

  group('FakeHealthPort', () {
    test('needs a grant before reading and returns the last N days', () async {
      final days = [for (var d = 1; d <= 25; d++) DailySignals(day: '2026-10-${d.toString().padLeft(2, '0')}', steps: d * 100)];
      final f = FakeHealthPort(days: days);
      await expectLater(f.readDaily(), throwsA(isA<HealthException>()));
      expect(await f.requestPermissions(), HealthPermission.granted);
      final r = await f.readDaily();
      expect(r.days, hasLength(21));
      expect(r.days.first.day, '2026-10-05');
      final none = FakeHealthPort(available: HealthAvailability.notInstalled);
      expect(await none.requestPermissions(), HealthPermission.unavailable);
    });
  });

  group('native contract', () {
    String read(String path) => File(path).readAsStringSync();

    test('HealthChannel.kt serves the same channel, methods and keys', () {
      final kt = read('$_kotlin/HealthChannel.kt');
      expect(kt, contains('"$healthChannelName"'));
      for (final m in ['availability', 'hasPermissions', 'requestPermissions', 'readDaily']) {
        expect(kt, contains('"$m"'), reason: m);
      }
      for (final k in ['"tz"', '"days"', '"day"', '"sleep_minutes"', '"steps"', '"resting_hr"']) {
        expect(kt, contains(k), reason: k);
      }
      expect(read('$_kotlin/MainActivity.kt'), contains('HealthChannel(this, messenger)'));
    });

    test('the manifest declares the three reads and the Android 14 rationale', () {
      final m = read('android/app/src/main/AndroidManifest.xml');
      for (final p in ['READ_SLEEP', 'READ_STEPS', 'READ_HEART_RATE']) {
        expect(m, contains('android.permission.health.$p'));
      }
      expect(m, contains('androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE'));
      expect(m, contains('android.intent.action.VIEW_PERMISSION_USAGE'));
      expect(m, contains('android.intent.category.HEALTH_PERMISSIONS'));
      expect(m, contains('android.permission.START_VIEW_PERMISSION_USAGE'));
      expect(m, isNot(contains('android.permission.health.WRITE_')));
    });
  });
}
