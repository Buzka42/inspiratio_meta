import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_scheduler.dart';
import 'package:illunis_client/alarm/exact_alarm_notice.dart';
import 'package:illunis_client/widgets/glass/glass_actions.dart';

import 'alarm_test.dart' show Rig, settings;

// Synthetic fixtures only; Dart fakes, no native code.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('needsExactAlarmGrant', () {
    test('true when canScheduleExact is false', () async {
      final r = Rig();
      r.scheduler.exactAllowed = false;
      await r.coordinator.start();
      expect(r.coordinator.needsExactAlarmGrant, isTrue);
    });

    test('false when canScheduleExact is true', () async {
      final r = Rig();
      await r.coordinator.start();
      expect(r.coordinator.needsExactAlarmGrant, isFalse);
    });

    test('a later grant clears it and schedules the saved alarm', () async {
      final r = Rig();
      r.scheduler.exactAllowed = false;
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings());
      expect(r.scheduler.scheduled, isNull);

      r.scheduler.exactAllowed = true;
      await r.coordinator.refreshExactAlarmGrant();
      expect(r.coordinator.needsExactAlarmGrant, isFalse);
      expect(r.scheduler.scheduled, settings());
      expect(r.coordinator.lastScheduleError, isNull);
    });
  });

  group('denied schedule', () {
    test('is reported with a code and does not crash', () async {
      final r = Rig();
      r.scheduler.exactAllowed = false;
      await r.coordinator.start();
      await r.coordinator.setAlarm(settings());
      expect(r.scheduler.scheduled, isNull);
      expect(r.coordinator.lastScheduleError, exactAlarmDeniedCode);
      expect(r.coordinator.needsExactAlarmGrant, isTrue);
      expect(r.logs, contains('alarm: not_scheduled code=exact_alarm_denied'));
    });

    test('method channel maps the platform error to its code', () async {
      const ch = MethodChannel('test/alarm_denied');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        if (call.method == AlarmChannel.schedule) {
          throw PlatformException(code: exactAlarmDeniedCode, message: 'off');
        }
        return null;
      });
      final logs = <String>[];
      final s = MethodChannelAlarmScheduler(channel: ch, log: logs.add);
      final r = await s.schedule(settings());
      expect(r.ok, isFalse);
      expect(r.code, exactAlarmDeniedCode);
    });
  });

  group('settings button', () {
    testWidgets('opens settings only when pressed', (tester) async {
      final r = Rig();
      r.scheduler.exactAllowed = false;
      await r.coordinator.start();
      expect(r.scheduler.settingsOpened, 0);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ExactAlarmNotice(
            visible: r.coordinator.needsExactAlarmGrant,
            onGrant: r.coordinator.openExactAlarmSettings,
          ),
        ),
      ));
      expect(find.text(exactAlarmNoticeText), findsOneWidget);
      expect(r.scheduler.settingsOpened, 0, reason: 'showing the notice opens nothing');

      // On the tokens and the shared action row, not a Material button.
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(GlassActions), findsOneWidget);
      final cell = find.ancestor(of: find.text(exactAlarmNoticeButton), matching: find.byType(InkWell));
      expect(tester.getSize(cell).height, greaterThanOrEqualTo(48));

      await tester.tap(find.text(exactAlarmNoticeButton));
      await tester.pump();
      expect(r.scheduler.settingsOpened, 1);
    });

    testWidgets('hidden when the grant is present', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ExactAlarmNotice(visible: false, onGrant: () => fail('pressed'))),
      ));
      expect(find.text(exactAlarmNoticeText), findsNothing);
      expect(find.text(exactAlarmNoticeButton), findsNothing);
    });
  });
}
