import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/council_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/view_offer.dart';
import 'package:illunis_client/memory/short_term_memory.dart';

import 'w5_fakes.dart';

// Synthetic questions, answers and sources only.
const big = 'Why do I keep waking up at 3am?';
const sources = [
  CouncilSource(id: 'nhs-sleep-1', title: 'NHS: insomnia'),
  CouncilSource(id: 'who-act-2', title: 'WHO: physical activity'),
  CouncilSource(id: 'web:1', title: 'A web page', kind: 'web'),
  CouncilSource(id: 'x', title: 'A fourth source'),
];

void main() {
  late FakeServerPort server;
  late Speaker sp;
  late FakeTimers timers;
  late int listens;
  late DateTime now;
  late List<(String, String)> answers;
  late CouncilFlow flow;

  CouncilFlow make({CouncilContext Function()? context}) => CouncilFlow(
        server: server,
        speaker: CouncilSpeaker(speak: sp.speak, caption: sp.caption),
        speak: sp.speak,
        listen: () => listens++,
        context: context ?? () => const CouncilContext(shortTermSummary: 'User: synthetic earlier turn'),
        onAnswer: (q, a) => answers.add((q, a)),
        timer: timers.call,
        clock: () => now,
        log: (_) {},
      );

  setUp(() {
    server = FakeServerPort(
        councilResult: const CouncilResult(synthesis: 'Synthetic synthesis.', sources: sources, medical: false));
    sp = Speaker();
    timers = FakeTimers();
    listens = 0;
    now = DateTime(2026, 10, 25, 22);
    answers = [];
    flow = make();
  });

  Future<void> offered(String q, {bool flag = false}) async {
    flow.afterAnswer(AnsweredTurn(transcript: q, answer: 'Synthetic reply.', councilSuggested: flag));
    await flow.settled;
  }

  test('a big question gets the offer after the reply, then listens for 8 s', () async {
    await offered(big);
    expect(sp.spoken, [CouncilPrompt.offer]);
    expect(listens, 1);
    expect(flow.offerOpen, isTrue);
    expect(timers.active.single.after, const Duration(seconds: 8));
    expect(server.councilCalls, isEmpty);
  });

  test('typed, the offer waits as long as a view offer (90 s); spoken, 8 s', () async {
    expect(councilOfferTimeout(voice: false), const Duration(seconds: 90));
    expect(councilOfferTimeout(voice: false), ViewOffer.timeout);
    expect(councilOfferTimeout(voice: true), const Duration(seconds: 8));
    flow = CouncilFlow(
      server: server,
      speaker: CouncilSpeaker(speak: sp.speak, caption: sp.caption),
      speak: sp.speak,
      answerTimeout: councilOfferTimeout(voice: false),
      timer: timers.call,
      log: (_) {},
    );
    await offered(big);
    expect(timers.active.single.after, const Duration(seconds: 90));
    // A yes before the timer fires (40 s in) still runs the council.
    expect(flow.claim('yes'), isTrue);
    await flow.settled;
    expect(server.councilRequests.single.question, big);
  });

  test('an ordinary question gets no offer; the reply flag alone does', () async {
    await offered('What time is it?');
    expect(sp.spoken, isEmpty);
    await offered('What time is it?', flag: true);
    expect(sp.spoken, [CouncilPrompt.offer]);
  });

  test('yes asks the council with the short-term context, speaks it, shows sources', () async {
    await offered(big);
    expect(flow.claim('yes please'), isTrue);
    await flow.settled;
    final r = server.councilRequests.single;
    expect(r.question, big);
    expect(r.purpose, 'chat');
    expect(r.context?.shortTermSummary, 'User: synthetic earlier turn');
    expect(sp.spoken.skip(1), [CouncilPrompt.asking, 'Synthetic synthesis.']);
    expect(sp.captions, ['Sources: NHS: insomnia · WHO: physical activity · A web page']);
    expect(answers, [(big, 'Synthetic synthesis.')]);
  });

  test('a medical answer always ends with the not-medical-advice line, once', () async {
    server.councilResult = const CouncilResult(synthesis: 'General information.', medical: true);
    await flow.ask(big);
    expect(sp.spoken.last, 'General information. $notMedicalAdviceLine');
    server.councilResult = const CouncilResult(synthesis: 'Info. $notMedicalAdviceLine', medical: true);
    await flow.ask(big);
    expect(sp.spoken.last, 'Info. $notMedicalAdviceLine');
  });

  test('crisis speaks the referral only: no sources, not remembered', () async {
    server.councilResult = const CouncilResult(synthesis: 'Synthetic referral.', crisis: true, sources: sources);
    await flow.ask(big);
    expect(sp.spoken.last, 'Synthetic referral.');
    expect(sp.captions, isEmpty);
    expect(answers, isEmpty);
  });

  test('no closes the offer and holds back new offers for the cooldown', () async {
    await offered(big);
    expect(flow.claim('no thanks'), isTrue);
    await flow.settled;
    expect(sp.spoken.last, CouncilPrompt.declined);
    await offered(big);
    expect(sp.spoken.where((s) => s == CouncilPrompt.offer), hasLength(1));
    now = now.add(const Duration(minutes: 11));
    await offered(big);
    expect(sp.spoken.where((s) => s == CouncilPrompt.offer), hasLength(2));
    expect(server.councilCalls, isEmpty);
  });

  test('silence closes the offer without a word; a later yes is a normal turn', () async {
    await offered(big);
    timers.fireActive();
    expect(flow.offerOpen, isFalse);
    expect(flow.claim('yes'), isFalse);
    expect(sp.spoken, [CouncilPrompt.offer]);
  });

  test('an unrelated answer closes the offer and is left for normal handling', () async {
    await offered(big);
    expect(flow.claim('what is the weather tomorrow'), isFalse);
    expect(flow.offerOpen, isFalse);
    expect(server.councilCalls, isEmpty);
  });

  test('an explicit ask runs at once, with its own question or the last big one', () async {
    expect(flow.claim('ask the council about my sleep getting worse'), isTrue);
    await flow.settled;
    expect(server.councilCalls.last, 'my sleep getting worse');
    await offered(big);
    timers.fireActive();
    expect(flow.claim('ask the council'), isTrue);
    await flow.settled;
    expect(server.councilCalls.last, big);
  });

  test('an explicit ask with no question at all asks for one', () async {
    expect(flow.claim('ask the council'), isTrue);
    await flow.settled;
    expect(sp.spoken.single, CouncilPrompt.needQuestion);
    expect(server.councilCalls, isEmpty);
  });

  test('a failed council call says so and logs a code only', () async {
    final logs = <String>[];
    server.councilError = const ServerException(503, 'not_configured', 'META_API_KEY missing');
    final f = CouncilFlow(
        server: server,
        speaker: CouncilSpeaker(speak: sp.speak),
        speak: sp.speak,
        log: logs.add);
    await f.ask(big);
    expect(sp.spoken.last, CouncilPrompt.unavailable);
    expect(logs, ['council: failed code=not_configured']);
  });

  test('councilContextFrom: summaries and the newest turns, oldest first', () async {
    final st = ShortTermMemory(
        store: InMemoryStateStore(),
        summarise: ({required turns, required startedAt, required endedAt}) async => 'Synthetic summary.');
    await st.load();
    await st.addExchange(user: 'q1', assistant: 'a1');
    await st.endSession();
    for (var i = 2; i <= 5; i++) {
      await st.addExchange(user: 'q$i', assistant: 'a$i');
    }
    final c = councilContextFrom(st, turns: 4);
    expect(c.shortTermSummary, 'Earlier: Synthetic summary.\nUser: q4\nIllunis: a4\nUser: q5\nIllunis: a5');
    expect(councilContextFrom(null).toJson(), isEmpty);
  });

  test('sourcesCaption caps titles and drops repeats', () {
    expect(sourcesCaption(const []), isNull);
    final long = 'L' * 80;
    expect(sourcesCaption([CouncilSource(id: 'a', title: long), CouncilSource(id: 'b', title: long)]),
        'Sources: ${'L' * 59}…');
    // One ellipsis character, never three dots; still 60 characters.
    final cut = sourcesCaption([CouncilSource(id: 'a', title: long)])!.substring('Sources: '.length);
    expect(cut.length, 60);
    expect(cut, isNot(contains('...')));
  });
}
