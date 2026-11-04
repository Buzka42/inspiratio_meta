import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/voice/alarm_digest.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Synthetic fixtures only.
const today = LocalDate(2026, 10, 23);

Future<MorningFlow> interviewed(SilentTts tts, FakeServerPort server, {SpeechOutput? speech}) async {
  final f = MorningFlow(tts: tts, server: server, alarm: const LocalTime(7, 0), speech: speech);
  await f.start();
  await f.answer(const Acknowledge());
  await f.answer(const ProactiveAnswer(ProactiveMode.wait));
  await f.answer(const KeywordAnswer('Altair'));
  await f.answer(const PersonalityAnswer('coach', skillPackId: 'training'));
  await f.answer(const ConfirmAnswer(true));
  return f;
}

void main() {
  test('interview speaks each prompt and yields a profile', () async {
    final tts = SilentTts();
    final f = await interviewed(tts, FakeServerPort());
    expect(f.interviewDone, isTrue);
    expect(tts.spoken, hasLength(6));
    expect(tts.spoken.first, startsWith('Good morning. I am Illunis.'));
    expect(tts.spoken.last, startsWith('All set.'));
    expect(f.profile!.keyword, 'altair');
    expect(f.profile!.proactive, isFalse);
    expect(f.profile!.personalityId, 'coach');
    expect(f.profile!.skillPackId, 'training');
  });

  test('rejected keyword re-prompts and wrong answers repeat the prompt', () async {
    final tts = SilentTts();
    final f = MorningFlow(tts: tts, server: FakeServerPort());
    await f.answer(const ConfirmAnswer(true)); // wrong kind at greet
    expect(f.interview.step, InterviewStep.greet);
    expect(tts.spoken.single, startsWith('Good morning.'));
    await f.answer(const Acknowledge());
    await f.answer(const ProactiveAnswer(ProactiveMode.proactive));
    await f.answer(const KeywordAnswer('hello'));
    expect(f.interview.step, InterviewStep.askWakeKeyword);
    expect(tts.spoken.last, contains('too common'));
    expect(f.profile, isNull);
  });

  test('no digest before the interview or without an alarm', () async {
    final server = FakeServerPort();
    final f = MorningFlow(tts: SilentTts(), server: server, alarm: const LocalTime(7, 0));
    expect(await f.tick(now: const LocalTime(7, 5), today: today), isNull);
    final g = await interviewed(SilentTts(), server)
      ..alarm = null;
    expect(await g.tick(now: const LocalTime(7, 5), today: today), isNull);
    expect(server.digestCalls, isEmpty);
  });

  test('digest fires once at the alarm with the chosen personality', () async {
    final tts = SilentTts();
    final server = FakeServerPort(
        digestResult: const DigestResult(text: 'Morning digest.', health: true, disclaimer: 'Not advice.'));
    final f = await interviewed(tts, server);
    tts.spoken.clear();
    const findings = [Finding('synthetic resting value rose', kind: 'health', confidence: 0.4)];

    expect(await f.tick(now: const LocalTime(6, 59), today: today, findings: findings), isNull);
    final d = await f.tick(now: const LocalTime(7, 0), today: today, findings: findings);
    expect(d?.text, 'Morning digest.');
    expect(tts.spoken, ['Morning digest.', 'Not advice.']);
    expect(server.digestCalls.single.personalityId, 'coach');
    expect(server.digestCalls.single.skillPackId, 'training');
    expect(server.digestCalls.single.findings, findings);

    expect(await f.tick(now: const LocalTime(7, 30), today: today), isNull);
    expect(server.digestCalls, hasLength(1));
    // Outside the catch-up window on the next day nothing fires.
    expect(await f.tick(now: const LocalTime(11, 0), today: const LocalDate(2026, 10, 24)), isNull);
  });

  test('a failed digest call is retried on the next tick', () async {
    final server = _FailingOnce();
    final f = await interviewed(SilentTts(), server);
    await expectLater(f.tick(now: const LocalTime(7, 1), today: today), throwsA(isA<ServerException>()));
    expect(f.lastFired, isNull);
    expect(await f.tick(now: const LocalTime(7, 2), today: today), isNotNull);
    expect(f.lastFired, today);
  });

  group('digest through cancellable speech', () {
    const digestText = 'Synthetic zebra digest. Second quokka line.';
    late FakeTtsEngine engine;
    late List<String> logs;
    late AppController c;
    late MorningFlow f;
    late FakeServerPort server;

    setUp(() async {
      engine = FakeTtsEngine(autoFinish: false);
      logs = [];
      server = FakeServerPort(
          digestResult: const DigestResult(text: digestText, health: true, disclaimer: 'Synthetic disclaimer.'));
      c = AppController(
          fog: FogSettings(InMemoryKeyValueStore()),
          server: server,
          tts: SilentTts(),
          speech: SpeechOutput(engine, log: logs.add),
          log: logs.add);
      f = await interviewed(SilentTts(), server, speech: c.speech);
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('plays sentence by sentence, then the disclaimer', () async {
      final d = f.tick(now: const LocalTime(7, 0), today: today);
      for (var i = 0; i < 3; i++) {
        await settle();
        engine.finishPlay();
      }
      expect((await d)?.text, digestText);
      expect(engine.played, ['Synthetic zebra digest.', 'Second quokka line.', 'Synthetic disclaimer.']);
    });

    test('the wake word mid-digest cancels it and opens listening', () async {
      final d = f.tick(now: const LocalTime(7, 0), today: today);
      await settle();
      expect(engine.isPlaying, isTrue);
      expect(c.voice, VoiceState.idle); // The digest is not a voice turn.

      c.dispatch(const WakeWordHeard());
      expect(await d, isNotNull);
      await settle();
      expect(engine.stops, greaterThanOrEqualTo(1));
      expect(engine.played, isEmpty);
      expect(engine.trace.where((t) => t.startsWith('play:')), ['play:Synthetic zebra digest.']);
      expect(c.voice, VoiceState.listening);
      expect(f.lastFired, today); // Interrupted, not replayed.
      expect(await f.tick(now: const LocalTime(7, 5), today: today), isNull);
    });

    test('a barge-in mid-digest cancels it too', () async {
      final d = f.tick(now: const LocalTime(7, 0), today: today);
      await settle();
      c.dispatch(const BargeIn());
      await d;
      expect(engine.played, isEmpty);
      expect(c.voice, VoiceState.listening);
    });

    test('no log line carries digest text', () async {
      engine
        ..autoFinish = true
        ..failOn = 'Second quokka line.';
      await f.tick(now: const LocalTime(7, 0), today: today);
      expect(logs, ['speech: synth_failed']);
      for (final line in logs) {
        for (final word in ['zebra', 'quokka', 'disclaimer']) {
          expect(line.contains(word), isFalse, reason: 'log leaked text: $line');
        }
      }
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
