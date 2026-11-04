// Typed onboarding and the steps before a session: a yes on a screen
// question stops that session, the advanced answer is stored (never
// inferred), and nothing reaches BreathReady without a yes to start.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/breath/breath_library.dart';
import 'package:illunis_client/breath/breath_onboarding.dart';
import 'package:illunis_client/breath/technique.dart';

import 'breath_fixtures.dart';

final lib = loadAssetLibrary();

({BreathFlow flow, InMemoryStateStore store, List<String> logs}) rig({String? named, BreathLibrary? library}) {
  final store = InMemoryStateStore();
  final logs = <String>[];
  final l = library ?? lib;
  final flow = BreathFlow(
    library: l,
    profiles: BreathProfileStore(store),
    requested: named == null ? null : l.match(named),
    log: logs.add,
  );
  return (flow: flow, store: store, logs: logs);
}

AskKind? ask(BreathFlow f) => switch (f.step) {
      BreathAsk(:final kind) => kind,
      _ => null,
    };

Future<void> onboard(BreathFlow f, {bool advanced = false}) async {
  await f.start();
  expect(ask(f), AskKind.intro);
  await f.answer(true);
  expect(ask(f), AskKind.how);
  await f.answer(true);
  expect(ask(f), AskKind.screen);
  expect((f.step as BreathAsk).screen, ScreenKind.standard);
  await f.answer(false);
  expect(ask(f), AskKind.advanced);
  expect((f.step as BreathAsk).question, advancedQuestion);
  await f.answer(advanced);
}

void main() {
  test('first run: intro, how it works, the default screen, then the advanced question', () async {
    final r = rig(named: 'box breathing');
    await onboard(r.flow);
    final saved = BreathProfile.decode(await r.store.getString(breathProfileKey))!;
    expect(saved.advanced, isFalse);
    expect(saved.cleared, {ScreenKind.standard});
    expect(ask(r.flow), AskKind.start);
    expect((r.flow.step as BreathAsk).question, 'Start Box, fixed count now?');
    await r.flow.answer(true);
    expect(r.flow.step, isA<BreathReady>());
    expect((r.flow.step as BreathReady).technique.id, 'box_breathing');
    expect(r.logs.join(' '), isNot(contains('box')));
  });

  test('the intro says what the sessions are and are not', () async {
    final r = rig();
    await r.flow.start();
    final body = (r.flow.step as BreathAsk).body!;
    expect(body, contains('not medical advice'));
    expect(body, contains('not a treatment'));
    await r.flow.answer(true);
    final how = (r.flow.step as BreathAsk).body!;
    expect(how, contains('Stop'));
    expect(how, contains('Pause'));
    expect(how, contains('cues are optional'));
  });

  test('a yes on a screen question shows the clinician notice and the session does not run', () async {
    final r = rig(named: 'paced breath');
    await r.flow.start();
    await r.flow.answer(true);
    await r.flow.answer(true);
    expect((r.flow.step as BreathAsk).question, screenQuestion);
    expect((r.flow.step as BreathAsk).items, contains('Epilepsy or seizures'));
    await r.flow.answer(true);
    final s = r.flow.step as BreathNotice;
    expect(s.notice, lib.byId('paced_breath')!.copy.notice);
    expect(s.notice, contains('clinician'));
    // Nothing else answers it into a session.
    await r.flow.answer(true);
    r.flow.choose('paced breath');
    expect(r.flow.step, isA<BreathNotice>());
    expect(await r.store.getString(breathProfileKey), isNull);
    expect(r.logs, contains('breath: screen_yes'));
  });

  test('the advanced answer is stored as given', () async {
    for (final advanced in [true, false]) {
      final r = rig();
      await onboard(r.flow, advanced: advanced);
      expect(BreathProfile.decode(await r.store.getString(breathProfileKey))!.advanced, advanced);
      expect(r.flow.step, isA<BreathChoose>());
    }
  });

  test('an advanced technique is refused without the stored flag and offered with it', () async {
    final no = rig(named: 'ocean breath');
    await onboard(no.flow);
    expect((no.flow.step as BreathNotice).text, contains('advanced'));

    final yes = rig(named: 'ocean breath');
    await onboard(yes.flow, advanced: true);
    expect(ask(yes.flow), AskKind.start);
  });

  test('a second run skips onboarding and keeps the stored answers', () async {
    final r = rig();
    await r.store.setString(breathProfileKey, const BreathProfile(advanced: false, cleared: {ScreenKind.standard}).encode());
    await r.flow.start();
    expect(r.flow.step, isA<BreathChoose>());
    r.flow.choose('no such technique');
    expect((r.flow.step as BreathChoose).miss, isTrue);
    r.flow.showList();
    expect((r.flow.step as BreathChoose).listed!.map((t) => t.id), lib.basics().map((t) => t.id));
    r.flow.choose('Long exhale');
    expect(ask(r.flow), AskKind.start);
    await r.flow.answer(false);
    expect(r.flow.step, isA<BreathNotice>());
  });

  test('a damaged stored record runs onboarding again', () async {
    final r = rig();
    await r.store.setString(breathProfileKey, '{not json');
    await r.flow.start();
    expect(ask(r.flow), AskKind.intro);
  });

  test('a no to the intro ends with no session and nothing stored', () async {
    final r = rig(named: 'box breathing');
    await r.flow.start();
    await r.flow.answer(false);
    expect(r.flow.step, isA<BreathNotice>());
    expect(await r.store.getString(breathProfileKey), isNull);
  });

  test('holotropic is explained with the clinician notice and never reaches a session', () async {
    final r = rig(named: 'holotropic breathing');
    await onboard(r.flow, advanced: true);
    final s = r.flow.step as BreathNotice;
    expect(s.text, contains('cannot be guided'));
    expect(s.notice, contains('clinician'));
  });

  test('only a plain typed yes or no counts as an answer', () {
    for (final y in ['yes', 'Yes.', ' YES ', 'y', 'yeah', 'yep', 'yes please']) {
      expect(typedYesNo(y), isTrue, reason: y);
    }
    for (final n in ['no', 'No!', 'n', 'nope', 'no thanks']) {
      expect(typedYesNo(n), isFalse, reason: n);
    }
    for (final x in ['', 'not sure', 'maybe', 'yes and no', 'I have epilepsy', 'no idea', 'ok']) {
      expect(typedYesNo(x), isNull, reason: x);
    }
  });

  test('typed answers walk the same onboarding and store the same answers', () async {
    final r = rig(named: 'box breathing');
    await r.flow.start();
    await r.flow.answerTyped('yes');
    expect(ask(r.flow), AskKind.how);
    await r.flow.answerTyped('Yes.');
    expect(ask(r.flow), AskKind.screen);
    await r.flow.answerTyped('no');
    expect(ask(r.flow), AskKind.advanced);
    await r.flow.answerTyped('nope');
    final saved = BreathProfile.decode(await r.store.getString(breathProfileKey))!;
    expect(saved.advanced, isFalse);
    expect(saved.cleared, {ScreenKind.standard});
    await r.flow.answerTyped('yes');
    expect(r.flow.step, isA<BreathReady>());
  });

  test('an unclear typed answer keeps the question and stores nothing', () async {
    final r = rig(named: 'box breathing');
    await r.flow.start();
    await r.flow.answer(true);
    await r.flow.answer(true);
    await r.flow.answerTyped('not sure');
    final s = r.flow.step as BreathAsk;
    expect(s.kind, AskKind.screen);
    expect(s.miss, isTrue);
    expect(s.items, screenItems[ScreenKind.standard]);
    expect(await r.store.getString(breathProfileKey), isNull);
    // A typed yes on the screen still stops the session.
    await r.flow.answerTyped('yes');
    expect(r.flow.step, isA<BreathNotice>());
    expect(await r.store.getString(breathProfileKey), isNull);
  });

  test('a typed yes to the advanced question is stored as advanced', () async {
    final r = rig(named: 'ocean breath');
    await r.flow.start();
    await r.flow.answer(true);
    await r.flow.answer(true);
    await r.flow.answer(false);
    expect((r.flow.step as BreathAsk).body, advancedBody);
    await r.flow.answerTyped('yes');
    expect(BreathProfile.decode(await r.store.getString(breathProfileKey))!.advanced, isTrue);
    expect(ask(r.flow), AskKind.start);
  });

  test("a technique's own screen is asked before its session; a yes stops it", () async {
    final forceful = Technique(
      id: 'synthetic_forceful',
      name: 'Synthetic forceful',
      aliases: const [],
      kind: TechniqueKind.breath,
      level: TechniqueLevel.advanced,
      evidence: Evidence.practitioner,
      available: true,
      durationS: 60,
      countInCycles: 3,
      pacing: const Pacing(phases: [BreathPhase(BreathPhaseKind.inhale, 5), BreathPhase(BreathPhaseKind.exhale, 5)], rateBpm: 6),
      cues: const [],
      screens: const [ScreenKind.standard, ScreenKind.forceful],
      stopPrompts: const [],
      copy: const TechniqueCopy(intent: 'Synthetic.', end: 'Synthetic end.', notice: 'Synthetic notice, see a clinician.'),
    );
    final l = BreathLibrary([forceful]);
    final stopped = rig(named: 'synthetic forceful', library: l);
    await onboard(stopped.flow, advanced: true);
    expect((stopped.flow.step as BreathAsk).screen, ScreenKind.forceful);
    await stopped.flow.answer(true);
    expect((stopped.flow.step as BreathNotice).notice, 'Synthetic notice, see a clinician.');

    final cleared = rig(named: 'synthetic forceful', library: l);
    await onboard(cleared.flow, advanced: true);
    await cleared.flow.answer(false);
    expect(ask(cleared.flow), AskKind.start);
    expect(BreathProfile.decode(await cleared.store.getString(breathProfileKey))!.cleared,
        {ScreenKind.standard, ScreenKind.forceful});
  });
}
