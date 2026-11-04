import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/health/checkin.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/tts_engine.dart';
import 'package:illunis_client/voice/alarm_digest.dart';
import 'package:illunis_client/voice/morning_interview.dart';

// Mood, energy and sleep check-ins. Synthetic answers only.
const day = '2026-10-25';

void main() {
  group('parseCheckIn', () {
    CheckIn? p(String s) => parseCheckIn(s, day: day);
    CheckIn c(int? m, int? e, int? s) => CheckIn(day: day, mood: m, energy: e, sleep: s);

    test('three numbers in order, as words or digits', () {
      expect(p('four three five'), c(4, 3, 5));
      expect(p('4, 3, 2.'), c(4, 3, 2));
      expect(p("I'd say a four, a three and a five"), c(4, 3, 5));
      expect(p('cztery trzy pięć'), c(4, 3, 5));
    });

    test('labels win over order, in any order', () {
      expect(p('sleep 2, mood 4, energy 3'), c(4, 3, 2));
      expect(p('my energy is three and mood is five'), c(5, 3, null));
      expect(p('mood four out of five, energy 3/5'), c(4, 3, null));
    });

    test('"all fours" sets all three; out-of-range numbers are ignored', () {
      expect(p('all fours'), c(4, 4, 4));
      expect(p('everything is a three'), c(3, 3, 3));
      expect(p('seven 9 two'), c(2, null, null));
    });

    test('nothing readable is null', () {
      expect(p('pretty good thanks'), isNull);
      expect(p(''), isNull);
    });

    test('declines', () {
      expect(isCheckInDecline('Skip.'), isTrue);
      expect(isCheckInDecline('not now'), isTrue);
      expect(isCheckInDecline('no four'), isFalse);
    });
  });

  group('CheckInStore', () {
    test('one entry per day, replaced; days past 60 dropped; oldest first', () async {
      final store = InMemoryStateStore();
      final s = CheckInStore(store, clock: () => DateTime(2026, 10, 25, 8));
      await s.save(const CheckIn(day: '2026-08-01', mood: 1)); // Older than 60 days.
      await s.save(const CheckIn(day: '2026-10-25', mood: 2, energy: 2, sleep: 2));
      await s.save(const CheckIn(day: '2026-10-24', mood: 3));
      await s.save(const CheckIn(day: '2026-10-25', mood: 5, energy: 4, sleep: 3));
      final all = await s.all();
      expect(all.map((c) => c.day), ['2026-10-24', '2026-10-25']);
      expect(all.last.mood, 5);
      final raw = jsonDecode((await store.getString(StoreKeys.checkIns))!) as Map;
      expect((raw['checkins'] as List).first, {'day': '2026-10-24', 'mood': 3, 'energy': null, 'sleep': null});
    });

    test('bad entries load as nothing', () async {
      final store = InMemoryStateStore();
      await store.setString(StoreKeys.checkIns, jsonEncode({'checkins': [{'day': 'x', 'mood': 3}, {'day': day, 'mood': 9}]}));
      expect(await CheckInStore(store).all(), isEmpty);
    });
  });

  group('CheckInSession', () {
    late InMemoryStateStore store;
    late List<String> spoken;
    late List<String> logs;
    late int listens;
    late CheckInSession s;

    setUp(() {
      store = InMemoryStateStore();
      spoken = [];
      logs = [];
      listens = 0;
      s = CheckInSession(
        checkIns: CheckInStore(store, clock: () => DateTime(2026, 10, 25, 8)),
        speak: (t) async => spoken.add(t),
        listen: () => listens++,
        clock: () => DateTime(2026, 10, 25, 8),
        log: logs.add,
      );
    });

    test('asks one question, stores the answer, and does not ask again today', () async {
      expect(s.claim('four three five'), isFalse); // Not asking yet.
      await s.ask();
      expect(spoken.single, CheckInPrompt.ask);
      expect(listens, 1);
      expect(s.claim('four three five'), isTrue);
      await s.settled;
      expect(spoken.last, 'Thank you. I noted mood 4, energy 3, sleep 5.');
      expect(await CheckInStore(store).forDay(day), const CheckIn(day: day, mood: 4, energy: 3, sleep: 5));
      await s.ask();
      expect(spoken.where((t) => t == CheckInPrompt.ask), hasLength(1));
      expect(logs, ['checkin: saved']);
    });

    test('re-asks once on an unreadable answer, then lets it go', () async {
      await s.ask();
      s.claim('zebra quokka');
      await s.settled;
      expect(spoken.last, CheckInPrompt.reask);
      expect(s.asking, isTrue);
      s.claim('still zebra');
      await s.settled;
      expect(spoken.last, CheckInPrompt.gaveUp);
      expect(s.asking, isFalse);
      expect(await CheckInStore(store).all(), isEmpty);
      expect(logs.join(' '), isNot(contains('zebra')));
    });

    test('"skip" stores nothing', () async {
      await s.ask();
      s.claim('skip');
      await s.settled;
      expect(spoken.last, CheckInPrompt.declined);
      expect(await CheckInStore(store).all(), isEmpty);
    });
  });

  group('MorningFlow.afterDigest', () {
    Future<MorningFlow> ready(SilentTts tts) async {
      final f = MorningFlow(
          tts: tts, server: FakeServerPort(), alarm: const LocalTime(7, 0), speech: SpeechOutput(TtsPortEngine(tts)));
      await f.answer(const Acknowledge());
      await f.answer(const ProactiveAnswer(ProactiveMode.wait));
      await f.answer(const KeywordAnswer('Altair'));
      await f.answer(const PersonalityAnswer('coach'));
      await f.answer(const ConfirmAnswer(true));
      return f;
    }

    test('runs after a digest that played to the end, once', () async {
      final tts = SilentTts();
      final f = await ready(tts);
      var asked = 0;
      f.afterDigest = () async => asked++;
      await f.tick(now: const LocalTime(7, 1), today: const LocalDate(2026, 10, 25));
      await f.tick(now: const LocalTime(7, 2), today: const LocalDate(2026, 10, 25));
      expect(asked, 1);
    });

    test('a failing follow-up never breaks the digest', () async {
      final f = await ready(SilentTts());
      f.afterDigest = () async => throw StateError('synthetic');
      expect(await f.tick(now: const LocalTime(7, 1), today: const LocalDate(2026, 10, 25)), isNotNull);
    });
  });
}
