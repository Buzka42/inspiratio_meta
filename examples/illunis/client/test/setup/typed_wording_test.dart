import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_settings.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/voice_setup.dart';
import 'package:illunis_client/health/checkin.dart';
import 'package:illunis_client/health/health_port.dart';
import 'package:illunis_client/health/health_setup.dart';
import 'package:illunis_client/memory/assistant_memory_backend.dart';
import 'package:illunis_client/memory/local_memory_backend.dart';
import 'package:illunis_client/memory/memory_mode.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/voice/setup_answers.dart';

// Typed onboarding (voice off): every prompt says "type" or "write", never a
// voice word, and typed answers are read. Synthetic answers only.

final _voiceWords = RegExp(r'\b(say|said|speak|spoken|aloud|tell me|hear|listen|wake word)\b', caseSensitive: false);

Matcher get _typedWording => isNot(matches(_voiceWords));

void _expectTyped(Iterable<String> prompts) {
  expect(prompts, isNotEmpty);
  for (final p in prompts) {
    expect(p, _typedWording, reason: p);
  }
}

void main() {
  group('interview (VoiceSetup typed)', () {
    test('every typed prompt and re-ask has no voice word', () async {
      final store = InMemoryStateStore();
      final tts = SilentTts();
      final flow = MorningFlow(tts: tts, server: FakeServerPort(), store: store);
      final setup = VoiceSetup(flow: flow, alarmStore: AlarmSettingsStore(store), typed: true, log: (_) {});
      await setup.start();
      // A junk answer before each real one, so every re-ask is shown.
      for (final (junk, answer) in const [
        ('...', 'Hi'),
        ('maybe', 'wait'),
        ('hmm', 'calm guide'),
        ('hmm', 'Habit building'),
        ('whenever', '07:15'),
        ('hmm', 'Y'),
      ]) {
        await setup.hear(junk);
        await setup.hear(answer);
      }
      expect(flow.interviewDone, isTrue);
      await setup.hear('change my alarm');
      await setup.hear('later');
      await setup.hear('6:45');
      expect(tts.spoken.last, 'Your alarm is set for 06:45.');
      _expectTyped(tts.spoken);
      expect(tts.spoken, containsAll([
        TypedSetupReask.greet,
        TypedSetupReask.proactive,
        TypedSetupReask.personality,
        TypedSetupReask.skillPack,
        TypedSetupReask.alarmTime,
        TypedSetupReask.confirm,
      ]));
    });

    test('typed constants and interview prompts; the spoken ones are unchanged', () {
      _expectTyped(const [
        TypedSetupReask.greet,
        TypedSetupReask.proactive,
        TypedSetupReask.personality,
        TypedSetupReask.skillPack,
        TypedSetupReask.alarmTime,
        TypedSetupReask.confirm,
        typedSkillPackPrompt,
        typedAlarmTimePrompt,
      ]);
      for (final s in InterviewStep.values.where((s) => s != InterviewStep.askWakeKeyword)) {
        expect(InterviewState(step: s, personalityId: 'calm_guide').promptFor(typed: true), _typedWording,
            reason: s.name);
      }
      expect(SetupReask.confirm, 'Please say yes or no.');
      expect(const InterviewState(step: InterviewStep.done).prompt,
          'All set. Say your wake word whenever you need me.');
    });
  });

  group('memory question (typed)', () {
    MemoryModeSetup build(List<String> shown, {bool typed = true}) => MemoryModeSetup(
          store: InMemoryStateStore(),
          backend: SelectedMemoryBackend(
              phone: LocalMemoryBackend(InMemoryStateStore()), assistant: AssistantMemoryBackend(FakeServerPort())),
          speak: (t) async => shown.add(t),
          typed: typed,
          log: (_) {},
        );

    test('asks "Type phone or assistant." and reads typed answers', () async {
      for (final (answer, mode) in const [
        ('Phone', MemoryMode.phone),
        ('phone.', MemoryMode.phone),
        ('ASSISTANT', MemoryMode.assistant),
        ('my assistant!', MemoryMode.assistant),
      ]) {
        final shown = <String>[];
        final s = build(shown);
        await s.offer();
        expect(shown.single, TypedMemoryModePrompt.offer);
        expect(shown.single, endsWith('Type phone or assistant.'));
        s.claim('not sure');
        await s.settled;
        expect(shown.last, 'Please type phone or assistant.');
        s.claim(answer);
        await s.settled;
        expect(s.mode, mode, reason: answer);
        _expectTyped(shown);
      }
    });

    test('voice on keeps the spoken wording', () async {
      final shown = <String>[];
      await build(shown, typed: false).offer();
      expect(shown.single, endsWith('Say phone or assistant.'));
    });
  });

  group('Health Connect question (typed)', () {
    late FakeHealthPort port;
    late List<String> shown;
    HealthSetup build({bool typed = true}) => HealthSetup(
        port: port, store: InMemoryStateStore(), speak: (t) async => shown.add(t), typed: typed, log: (_) {});

    setUp(() {
      port = FakeHealthPort();
      shown = [];
    });

    test('a typed yes opens the sheet; prompts say type', () async {
      port.grantOnRequest = HealthPermission.denied;
      final h = build();
      await h.offer();
      expect(shown.single, endsWith('Type yes or no.'));
      h.claim('dunno');
      await h.settled;
      expect(shown.last, 'Please type yes or no.');
      h.claim('Y');
      await h.settled;
      expect(port.permissionRequests, 1);
      expect(shown.last, TypedHealthPrompt.denied);
      _expectTyped(shown);
    });

    test('a typed no declines with typed wording', () async {
      final h = build();
      await h.offer();
      h.claim('No.');
      await h.settled;
      expect(port.permissionRequests, 0);
      expect(shown.last, 'All right. Type connect Health Connect if you change your mind.');
      _expectTyped(shown);
      expect(isHealthIntent('connect Health Connect'), isTrue);
    });

    test('voice on keeps the spoken wording', () async {
      await build(typed: false).offer();
      expect(shown.single, HealthPrompt.offer);
      expect(shown.single, endsWith('Say yes or no.'));
    });
  });

  group('check-in (typed)', () {
    test('the re-ask says type and typed numbers are read', () async {
      final shown = <String>[];
      final store = InMemoryStateStore();
      final s = CheckInSession(
        checkIns: CheckInStore(store, clock: () => DateTime(2026, 10, 25, 8)),
        speak: (t) async => shown.add(t),
        clock: () => DateTime(2026, 10, 25, 8),
        typed: true,
        log: (_) {},
      );
      await s.ask();
      s.claim('fine');
      await s.settled;
      expect(shown.last, CheckInPrompt.typedReask);
      s.claim('4/5 3 5');
      await s.settled;
      expect(await CheckInStore(store).forDay('2026-10-25'),
          const CheckIn(day: '2026-10-25', mood: 4, energy: 3, sleep: 5));
      _expectTyped(shown);
      expect(CheckInPrompt.reask, startsWith('Please say'));
    });
  });

  test('typed yes and no short forms are read', () {
    for (final y in ['yes', 'Yes.', 'Y', 'y', 'ok']) {
      expect(parseConfirm(y)?.yes, isTrue, reason: y);
    }
    for (final n in ['no', 'No!', 'N', 'n', 'nope']) {
      expect(parseConfirm(n)?.yes, isFalse, reason: n);
    }
    expect(parseConfirm('y n'), isNull);
  });
}
