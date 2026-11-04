// Ask before opening (PLAN.md rule 2026-10-28): a breathwork request is a
// Yes / No offer first, the view opens only through ViewHost after a yes,
// and a session plays only after a yes to "Start ... now?". Synthetic text,
// a fake engine (no audio) and an in-memory store.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/view_offer.dart';
import 'package:illunis_client/app/view_requests.dart';
import 'package:illunis_client/breath/breath_onboarding.dart';
import 'package:illunis_client/breath/breath_view.dart';
import 'package:illunis_client/breath/breath_voice.dart';
import 'package:illunis_client/breath/breath_wiring.dart';
import 'package:illunis_client/breath/technique.dart';
import 'package:illunis_client/output/speech_fakes.dart';

import 'breath_fixtures.dart';

final lib = loadAssetLibrary();

class _Timer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

({ViewOffer offer, ViewHost host, List<String> posts}) rig() {
  final host = ViewHost();
  final posts = <String>[];
  final offer = ViewOffer(host: host, post: (p, id) => posts.add(p), timer: (d, f) => _Timer(), log: (_) {});
  return (offer: offer, host: host, posts: posts);
}

class _Host extends StatelessWidget {
  const _Host(this.views, this.deps);
  final ViewHost views;
  final BreathDeps deps;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: ColoredBox(
          color: Colors.black,
          child: ListenableBuilder(
            listenable: views,
            builder: (context, _) => switch (views.current) {
              final v? when v.kind == ViewKind.breathwork =>
                BreathView(request: v, deps: deps, onClose: views.close),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
      );
}

Future<void> pumpHost(WidgetTester t, ViewHost views, BreathDeps deps, {bool reduceMotion = false}) async {
  t.view.physicalSize = const Size(320, 640);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(size: const Size(320, 640), disableAnimations: reduceMotion),
    child: _Host(views, deps),
  ));
  await t.pump();
}

Future<void> tapKey(WidgetTester t, Key k) async {
  await t.ensureVisible(find.byKey(k));
  await t.tap(find.byKey(k));
  await t.pump();
}

void main() {
  setUp(() => registerBreathNames(lib.names));
  tearDown(() => registerBreathNames(const []));

  group('requests', () {
    test('breathwork phrases and named techniques become requests', () {
      expect(parseViewRequest('start breathwork'), const ViewRequest(ViewKind.breathwork, 'breathwork'));
      expect(parseViewRequest('do a breathing session'), const ViewRequest(ViewKind.breathwork, 'breathwork'));
      expect(parseViewRequest('do box breathing'), const BreathRequest('box breathing'));
      expect(parseViewRequest('Please start a box breathing session.'), const BreathRequest('box breathing'));
      expect(parseViewRequest('try the body scan'), const BreathRequest('body scan'));
      expect(parseViewRequest('I want to do metta'), const BreathRequest('metta'));
      expect(parseViewRequest('do holotropic breathing'), const BreathRequest('holotropic breathing'));
    });

    test('questions and unknown names are not requests', () {
      for (final t in ['what is box breathing', 'is box breathing safe', 'do my taxes', 'try something calming',
          'start the day', 'box breathing']) {
        expect(parseViewRequest(t), isNull, reason: t);
      }
    });

    test('named techniques match only once the library has registered its names', () {
      registerBreathNames(const []);
      expect(parseViewRequest('do box breathing'), isNull);
      expect(parseViewRequest('start breathwork'), isNotNull);
    });
  });

  group('offers', () {
    test('a named request is offered and opens nothing without a yes', () {
      final r = rig();
      expect(r.offer.claim('do box breathing'), isTrue);
      expect(r.posts, ['Open box breathing?']);
      expect(r.host.current, isNull);
      expect(r.offer.claim('no'), isTrue);
      expect(r.host.current, isNull);

      r.offer.claim('start breathwork');
      r.offer.claim('what time is it'); // anything else cancels the offer
      expect(r.host.current, isNull);
      expect(r.offer.offerOpen, isFalse);

      r.offer.claim('do box breathing');
      r.offer.claim('yes');
      expect(r.host.current, const BreathRequest('box breathing'));
    });
  });

  group('view', () {
    late InMemoryStateStore store;
    late FakeTtsEngine engine;
    // Made inside each test body, so its futures run in the test's zone.
    BreathDeps makeDeps() =>
        BreathDeps(library: Future.value(lib), store: store, voice: BreathVoice(engine: engine, allowed: true));
    setUp(() {
      store = InMemoryStateStore();
      engine = FakeTtsEngine();
    });

    testWidgets('no view and no session before a yes; Start needs its own yes', (t) async {
      final r = rig();
      await pumpHost(t, r.host, makeDeps());
      r.offer.claim('do box breathing');
      await t.pump();
      expect(find.byType(BreathView), findsNothing);

      r.offer.claim('yes');
      await t.pump();
      await t.pump();
      expect(find.byType(BreathView), findsOneWidget);
      expect(find.textContaining('not medical advice'), findsOneWidget);
      expect(find.byKey(BreathView.visualKey), findsNothing);

      await tapKey(t, BreathView.yesKey); // intro
      await tapKey(t, BreathView.yesKey); // how it works
      await tapKey(t, BreathView.noKey); // default screen
      await tapKey(t, BreathView.noKey); // not advanced
      await t.pump();
      expect(find.text('Start Box, fixed count now?'), findsOneWidget);
      expect(find.byKey(BreathView.visualKey), findsNothing);
      expect(find.byKey(BreathView.stopKey), findsNothing);

      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(BreathView.visualKey), findsOneWidget);
      for (final k in [BreathView.stopKey, BreathView.pauseKey]) {
        final size = t.getSize(find.byKey(k));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
      }
      expect(find.textContaining('Getting ready'), findsOneWidget);

      // Count-in (3 x 16 s), then the first cue fires and is spoken.
      await t.pump(const Duration(seconds: 48));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text(lib.byId('box_breathing')!.cues.first.text), findsOneWidget);
      await t.runAsync(pumpEventQueue);
      expect(engine.played, [lib.byId('box_breathing')!.cues.first.text]);

      await tapKey(t, BreathView.pauseKey);
      expect(find.text('Resume'), findsOneWidget);
      expect(engine.stops, 1);
      await tapKey(t, BreathView.stopKey);
      expect(find.text(lib.byId('box_breathing')!.copy.end), findsOneWidget);
      await tapKey(t, BreathView.closeKey);
      expect(find.byType(BreathView), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('a yes on the screen question shows the notice and no session', (t) async {
      final r = rig();
      await pumpHost(t, r.host, makeDeps());
      r.offer.claim('start breathwork');
      r.offer.claim('yes');
      await t.pump();
      await t.pump();
      await tapKey(t, BreathView.yesKey);
      await tapKey(t, BreathView.yesKey);
      await tapKey(t, BreathView.yesKey); // screen: yes
      await t.pump();
      expect(find.text(defaultNotice), findsOneWidget);
      expect(find.byKey(BreathView.yesKey), findsNothing);
      expect(find.byKey(BreathView.visualKey), findsNothing);
      expect(find.byKey(BreathView.closeKey), findsOneWidget);
    });

    testWidgets('reduced motion shows a text countdown instead of the visual', (t) async {
      await store.setString(breathProfileKey,
          const BreathProfile(advanced: false, cleared: {ScreenKind.standard}).encode());
      final r = rig();
      await pumpHost(t, r.host, makeDeps(), reduceMotion: true);
      r.offer.claim('do paced breath');
      r.offer.claim('yes');
      await t.pump();
      await t.pump();
      expect(find.text('Start Paced breath now?'), findsOneWidget);
      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(BreathView.visualKey), findsNothing);
      expect(find.byKey(BreathView.countdownKey), findsOneWidget);
      // The phase above, the seconds left on the ring's centre.
      String count() => t.widget<Text>(find.byKey(BreathView.countdownKey)).data!;
      expect(find.text('Breathe in'), findsOneWidget);
      expect(count(), '5');
      await t.pump(const Duration(seconds: 5));
      expect(find.text('Breathe out'), findsOneWidget);
      expect(count(), '5');
      await tapKey(t, BreathView.stopKey);
      expect(t.takeException(), isNull);
    });

    testWidgets('typed choice: no list until asked, then basics in order', (t) async {
      await store.setString(breathProfileKey,
          const BreathProfile(advanced: false, cleared: {ScreenKind.standard}).encode());
      final r = rig();
      await pumpHost(t, r.host, makeDeps());
      r.offer.claim('start breathwork');
      r.offer.claim('yes');
      await t.pump();
      await t.pump();
      expect(find.byKey(BreathView.nameKey), findsOneWidget);
      expect(find.byKey(const ValueKey('breath-item-paced_breath')), findsNothing);
      await tapKey(t, BreathView.listKey);
      final ys = [
        for (final b in lib.basics()) t.getTopLeft(find.byKey(ValueKey('breath-item-${b.id}'))).dy,
      ];
      expect(ys, [...ys]..sort());
      expect(find.byKey(const ValueKey('breath-item-ujjayi')), findsNothing);
      await t.enterText(find.byKey(BreathView.nameKey), 'square breathing');
      await tapKey(t, BreathView.chooseKey);
      expect(find.text('Start Box, fixed count now?'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
