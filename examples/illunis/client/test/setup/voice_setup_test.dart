import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_settings.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/voice_setup.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/input/input_fakes.dart';
import 'package:illunis_client/input/input_pipeline.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Fakes and synthetic transcripts only.
class Rig {
  Rig(this.store, {bool typed = false}) : tts = SilentTts() {
    flow = MorningFlow(tts: tts, server: FakeServerPort(), store: store);
    setup = VoiceSetup(
      flow: flow,
      typed: typed,
      alarmStore: AlarmSettingsStore(store, log: logs.add),
      onKeywordChanged: () => refreshes++,
      listen: () => listens++,
      log: logs.add,
    );
  }

  final StateStore store;
  final SilentTts tts;
  late final MorningFlow flow;
  late final VoiceSetup setup;
  final logs = <String>[];
  int refreshes = 0;
  int listens = 0;

  Future<void> load() async {
    await flow.load();
    await setup.load();
  }

  Future<void> say(Iterable<String> lines) async {
    for (final l in lines) {
      await setup.hear(l);
    }
  }

  Future<AlarmSettings?> savedAlarm() => AlarmSettingsStore(store, log: logs.add).load();
}

const fullAnswers = [
  'Good morning.',
  'Proactive, please.',
  'Vega.',
  'The personal coach.',
  'Breathwork.',
  'seven thirty',
];

void main() {
  test('each step parses its spoken answer and moves on', () async {
    final r = Rig(InMemoryStateStore());
    await r.setup.start();
    expect(r.setup.step, SetupStep.greet);
    expect(r.tts.spoken.single, startsWith('Good morning. I am Illunis.'));

    const expected = [
      SetupStep.proactive,
      SetupStep.keyword,
      SetupStep.personality,
      SetupStep.skillPack,
      SetupStep.alarmTime,
      SetupStep.confirm,
    ];
    for (var i = 0; i < fullAnswers.length; i++) {
      await r.setup.hear(fullAnswers[i]);
      expect(r.setup.step, expected[i], reason: fullAnswers[i]);
    }
    expect(r.tts.spoken.last,
        'You chose proactive advice, the wake word vega, the personal coach for your digest '
        'with breathwork, and an alarm at 07:30. Is that right?');
    expect(r.refreshes, 1); // Keyword accepted.
    expect(r.listens, 7); // After every prompt that expects an answer.
  });

  test('unparseable answers re-ask the same step with a fixed prompt', () async {
    final r = Rig(InMemoryStateStore());
    await r.say(['hello']);
    final cases = [
      ('maybe later', SetupStep.proactive, SetupReask.proactive, 'wait'),
      ('my favourite star', SetupStep.keyword, SetupReask.keyword, 'Altair'),
      ('a pirate', SetupStep.personality, SetupReask.personality, 'socratic tutor'),
      ('juggling', SetupStep.skillPack, SetupReask.skillPack, 'none'),
      ('early', SetupStep.alarmTime, SetupReask.alarmTime, '6:45'),
      ('purple', SetupStep.confirm, SetupReask.confirm, null),
    ];
    for (final (bad, step, reask, good) in cases) {
      await r.setup.hear(bad);
      expect(r.setup.step, step, reason: bad);
      expect(r.tts.spoken.last, reask);
      if (good != null) await r.setup.hear(good);
    }
    expect(r.logs.where((l) => l.startsWith('setup: reask')), hasLength(6));
    // Logs never carry what was said.
    for (final l in r.logs) {
      expect(l, isNot(contains('pirate')));
      expect(l, isNot(contains('altair')));
    }
  });

  test('a common word as the wake keyword is rejected and re-asked', () async {
    final r = Rig(InMemoryStateStore());
    await r.say(['ok', 'wait', 'Hello.']);
    expect(r.setup.step, SetupStep.keyword);
    expect(r.tts.spoken.last, contains('too common'));
    expect(r.flow.interview.keyword, isNull);
    expect(r.refreshes, 0);
    await r.say(['abc']);
    expect(r.tts.spoken.last, contains('too short'));
    await r.say(['Altair']);
    expect(r.setup.step, SetupStep.personality);
    expect(r.refreshes, 1);
  });

  test('confirm saves the alarm, personality, skill pack, proactive flag and keyword', () async {
    final store = InMemoryStateStore();
    final r = Rig(store);
    await r.say([...fullAnswers, 'Yes.']);
    expect(r.setup.step, SetupStep.done);
    expect(r.flow.interviewDone, isTrue);
    expect(r.tts.spoken.last, startsWith('All set.'));
    expect(r.refreshes, 2); // Keyword step, then confirm.
    expect(r.logs, contains('setup: saved'));

    final alarm = (await r.savedAlarm())!;
    expect((alarm.hour, alarm.minute, alarm.enabled), (7, 30, true));
    expect(alarm.personalityId, 'personal_coach');
    expect(alarm.skillPackId, 'breathwork');

    // A fresh start reads the proactive flag and keyword back.
    final again = Rig(store);
    await again.load();
    expect(again.flow.interviewDone, isTrue);
    expect(again.flow.profile!.proactive, isTrue);
    expect(again.flow.profile!.keyword, 'vega');
    expect(again.setup.active, isFalse);
    expect(await store.getString(StoreKeys.voiceSetup), isNull); // Draft cleared.
    await again.setup.start();
    expect(again.tts.spoken, isEmpty); // Nothing to ask.
  });

  test('saves go through the guarded store', () async {
    final logs = <String>[];
    final r = Rig(GuardedStore(InMemoryStateStore(), log: logs.add));
    await r.say([...fullAnswers, 'yes']);
    expect((await r.savedAlarm())!.personalityId, 'personal_coach');
    expect(logs, isEmpty);
  });

  test('"no" at confirm restarts the questions and saves nothing', () async {
    final store = InMemoryStateStore();
    final r = Rig(store);
    await r.say([...fullAnswers, 'no']);
    expect(r.setup.step, SetupStep.proactive);
    expect(r.setup.draft.isEmpty, isTrue);
    expect(await r.savedAlarm(), isNull);
  });

  test('an interrupted interview resumes at the same step', () async {
    final store = InMemoryStateStore();
    final first = Rig(store);
    await first.say(fullAnswers.take(4)); // Up to the personality.
    expect(first.setup.step, SetupStep.skillPack);

    final second = Rig(store);
    await second.load();
    expect(second.setup.step, SetupStep.skillPack);
    await second.setup.start();
    expect(second.tts.spoken.single, skillPackPrompt);
    await second.say(['habit building', 'quarter to seven']);
    expect(second.setup.step, SetupStep.confirm);

    final third = Rig(store);
    await third.load();
    expect(third.setup.step, SetupStep.confirm);
    await third.say(['yes']);
    final alarm = (await third.savedAlarm())!;
    expect((alarm.hour, alarm.minute), (6, 45));
    expect(alarm.personalityId, 'personal_coach');
    expect(alarm.skillPackId, 'habit_building');
    expect(third.flow.profile!.keyword, 'vega');
  });

  test('resume after each step lands on that step', () async {
    final store = InMemoryStateStore();
    const steps = [
      SetupStep.proactive,
      SetupStep.keyword,
      SetupStep.personality,
      SetupStep.skillPack,
      SetupStep.alarmTime,
      SetupStep.confirm,
    ];
    for (var i = 0; i < fullAnswers.length; i++) {
      final r = Rig(store);
      await r.load();
      await r.say([fullAnswers[i]]);
      final resumed = Rig(store);
      await resumed.load();
      expect(resumed.setup.step, steps[i]);
    }
  });

  test('a corrupt draft is dropped, the interview step is kept', () async {
    final store = InMemoryStateStore();
    final r = Rig(store);
    await r.say(fullAnswers.take(4));
    await store.setString(StoreKeys.voiceSetup, '{not json');
    final again = Rig(store);
    await again.load();
    expect(again.setup.step, SetupStep.personality);
    await store.setString(StoreKeys.voiceSetup, '{"personality_id":"pirate","alarm":"99:99"}');
    await again.load();
    expect(again.setup.step, SetupStep.personality);
  });

  group('spoken changes after setup', () {
    late InMemoryStateStore store;
    late Rig r;
    setUp(() async {
      store = InMemoryStateStore();
      r = Rig(store);
      await r.say([...fullAnswers, 'yes']);
      r.tts.spoken.clear();
      r.refreshes = 0;
    });

    test('"change my alarm to 6:45" saves only the time', () async {
      expect(r.setup.claim('Change my alarm to 6:45.'), isTrue);
      await r.setup.settled;
      final a = (await r.savedAlarm())!;
      expect((a.hour, a.minute), (6, 45));
      expect(a.personalityId, 'personal_coach');
      expect(a.skillPackId, 'breathwork');
      expect(r.tts.spoken, ['Your alarm is set for 06:45.']);
      expect(r.flow.interviewDone, isTrue);
      expect(r.setup.active, isFalse);
    });

    test('"change my alarm" asks for the time, re-asks a bad one, survives a restart', () async {
      await r.say(['change my alarm']);
      expect(r.setup.step, SetupStep.alarmTime);
      expect(r.tts.spoken.last, alarmTimePrompt);
      await r.say(['whenever']);
      expect(r.tts.spoken.last, SetupReask.alarmTime);

      final again = Rig(store);
      await again.load();
      expect(again.setup.step, SetupStep.alarmTime);
      await again.say(['six fifteen']);
      expect((await again.savedAlarm())!.minute, 15);
      expect(again.setup.active, isFalse);
    });

    test('"change my wake word to X" validates, saves and refreshes', () async {
      await r.say(['change my wake word to hello']);
      expect(r.tts.spoken.last, contains('too common'));
      expect(r.setup.step, SetupStep.keyword);
      expect(r.refreshes, 0);
      await r.say(['Deneb.']);
      expect(r.flow.interview.keyword!.word, 'deneb');
      expect(r.flow.profile!.keyword, 'deneb');
      expect(r.refreshes, 1);
      expect(r.tts.spoken.last, 'Your wake word is now deneb.');

      final again = Rig(store);
      await again.load();
      expect(again.flow.interview.keyword!.word, 'deneb');
      expect(again.flow.interview.proactive, isTrue);
      expect(again.flow.interview.personalityId, 'personal_coach');
    });

    test('other speech is not claimed after setup', () {
      expect(r.setup.claim('how did I sleep'), isFalse);
      expect(r.setup.claim('zoom in on the moon'), isFalse);
    });
  });

  test('a change at the confirmation returns to the confirmation', () async {
    final r = Rig(InMemoryStateStore());
    await r.say([...fullAnswers, 'change my alarm to 6:45']);
    expect(r.setup.step, SetupStep.confirm);
    expect(r.tts.spoken.last, contains('an alarm at 06:45'));
    await r.say(['change my wake word to Rigel']);
    expect(r.setup.step, SetupStep.confirm);
    expect(r.tts.spoken.last, contains('the wake word rigel'));
    await r.say(['yes']);
    expect((await r.savedAlarm())!.hour, 6);
    expect(r.flow.profile!.keyword, 'rigel');
  });

  test('transcripts from SpeechToTextPort drive the interview end to end', () async {
    final store = InMemoryStateStore();
    final tts = SilentTts();
    final c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: tts);
    final turns = <TurnRequest>[];
    c.turnRequests.listen(turns.add);
    final flow = MorningFlow(tts: tts, server: FakeServerPort(), store: store);
    final capture = FakeAudioCapture();
    final stt = FakeSpeechToText([
      for (final a in [...fullAnswers, 'yes']) Utterance(a, isFinal: true),
    ]);
    final wake = FakeWakeWordPort(const []);
    late InputPipeline input;
    input = InputPipeline(
      controller: c,
      permission: FakeMicPermission(),
      capture: capture,
      wakeWord: wake,
      stt: stt,
      keyword: () => flow.interview.keyword,
      log: (_) {},
    );
    final setup = VoiceSetup(
      flow: flow,
      alarmStore: AlarmSettingsStore(store),
      onKeywordChanged: input.refreshKeyword,
      listen: () {
        if (input.status == InputStatus.running) c.dispatch(const WakeWordHeard());
      },
      log: (_) {},
    );
    c.setupHook = setup.claim;
    expect(await input.start(), isTrue);
    await setup.start();
    expect(c.voice, VoiceState.listening);

    for (var i = 0; i < 7; i++) {
      expect(input.sessionOpen, isTrue, reason: 'answer $i');
      capture.emit();
      await setup.settled;
    }
    expect(setup.step, SetupStep.done);
    expect(c.voice, VoiceState.idle);
    expect(input.sessionOpen, isFalse);
    expect(turns, isEmpty); // No answer became a server turn.
    expect(wake.listens, 2); // Spotting restarted with the new keyword twice.
    final a = (await AlarmSettingsStore(store).load())!;
    expect((a.hour, a.minute, a.personalityId), (7, 30, 'personal_coach'));

    // After setup, normal speech becomes a turn again.
    c.dispatch(const WakeWordHeard());
    stt.addUtterances(const [Utterance('plan my day', isFinal: true)]);
    capture.emit();
    expect(turns.map((t) => t.text), ['plan my day']);
    await input.dispose();
  });

  test('the interview state machine still accepts parsed answers as before', () async {
    // MorningFlow.answer is unchanged; VoiceSetup only adds parsing around it.
    final f = MorningFlow(tts: SilentTts(), server: FakeServerPort());
    await f.answer(const Acknowledge());
    expect(f.interview.step, InterviewStep.askProactive);
  });

  group('typed onboarding (voice off)', () {
    const typedAnswers = ['Hello', 'proactive', 'personal coach', 'none', '7:30'];

    test('skips the wake keyword step and uses typed wording', () async {
      final r = Rig(InMemoryStateStore(), typed: true);
      await r.setup.start();
      expect(r.setup.step, SetupStep.greet);
      const expected = [
        SetupStep.proactive,
        SetupStep.personality,
        SetupStep.skillPack,
        SetupStep.alarmTime,
        SetupStep.confirm,
      ];
      for (var i = 0; i < typedAnswers.length; i++) {
        await r.setup.hear(typedAnswers[i]);
        expect(r.setup.step, expected[i], reason: typedAnswers[i]);
      }
      expect(r.tts.spoken.any((p) => p.startsWith('Choose a word to wake me')), isFalse);
      expect(r.tts.spoken.last, contains('Is that right?'));
      expect(r.tts.spoken.last, isNot(contains('wake word')));
      expect(r.tts.spoken.where((p) => p.contains('Or type none.')), isNotEmpty);

      await r.setup.hear('yes');
      expect(r.setup.step, SetupStep.done);
      expect(r.flow.interviewDone, isTrue);
      expect(r.flow.interview.keyword?.word, typedDefaultKeyword);
      expect(r.tts.spoken.last, 'All set. Type a message whenever you need me.');
      expect((await r.savedAlarm())?.personalityId, isNotNull);
    });

    test('typed re-asks say type, and a finished typed interview survives a restart', () async {
      final store = InMemoryStateStore();
      final r = Rig(store, typed: true);
      await r.setup.start();
      await r.setup.hear('Hello');
      await r.setup.hear('maybe');
      expect(r.tts.spoken.last, TypedSetupReask.proactive);
      for (final a in typedAnswers.skip(1)) {
        await r.setup.hear(a);
      }
      await r.setup.hear('yes');

      final again = Rig(store, typed: true);
      await again.load();
      expect(again.flow.interviewDone, isTrue);
      expect(again.setup.active, isFalse);
    });

    test('a voice interview saved at the keyword step continues past it', () async {
      final store = InMemoryStateStore();
      final voice = Rig(store);
      await voice.setup.start();
      await voice.say(['Good morning.', 'Proactive, please.']);
      expect(voice.setup.step, SetupStep.keyword);

      final typed = Rig(store, typed: true);
      await typed.load();
      await typed.setup.start();
      expect(typed.setup.step, SetupStep.personality);
    });

    test('"change my wake word" is not taken when typed', () async {
      final r = Rig(InMemoryStateStore(), typed: true);
      await r.setup.start();
      for (final a in [...typedAnswers, 'yes']) {
        await r.setup.hear(a);
      }
      expect(r.setup.claim('change my wake word to Vega'), isFalse);
      expect(r.setup.claim('change my alarm to 6:45'), isTrue);
    });
  });
}
