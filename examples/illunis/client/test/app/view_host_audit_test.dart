// Every view the app can open, in the real IllunisRoot at 360 px: nothing
// opens before the offer's yes (PLAN.md rule 2026-10-28), each opens from a
// tapped yes, fits, covers the sky while open, and its own Close returns to
// the sky with the composer usable again. Taps, long presses and swipes on
// the sky open nothing, and a council offer's yes opens no view.
// Synthetic text, in-memory stores, no audio.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/illunis_root.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/view_offer.dart';
import 'package:illunis_client/app/view_requests.dart';
import 'package:illunis_client/breath/breath_onboarding.dart';
import 'package:illunis_client/breath/breath_view.dart';
import 'package:illunis_client/breath/breath_wiring.dart';
import 'package:illunis_client/breath/technique.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/logs/log_store.dart';
import 'package:illunis_client/logs/views/activity_view.dart';
import 'package:illunis_client/logs/views/cardio_view.dart';
import 'package:illunis_client/logs/views/day_view.dart';
import 'package:illunis_client/logs/views/food_view.dart';
import 'package:illunis_client/logs/views/log_frame.dart';
import 'package:illunis_client/logs/views/run_view.dart';
import 'package:illunis_client/logs/views/strength_view.dart';
import 'package:illunis_client/logs/views/wellbeing_view.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/thread_engine.dart';
import 'package:illunis_client/ui/tokens.dart';
import 'package:illunis_client/widgets/chat_composer.dart';

import '../breath/breath_fixtures.dart';
import '../logs/log_fixtures.dart' as fx;
import 'view_audit_helpers.dart';

final lib = loadAssetLibrary();

class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

/// The phrase that requests each view, and the key of its own Close.
const views = <ViewKind, (String, Key)>{
  ViewKind.logs: ('show my logs', LogKeys.close),
  ViewKind.food: ('show my food log', LogKeys.close),
  ViewKind.activity: ('open my activity log', LogKeys.close),
  ViewKind.strength: ('show my strength log', LogKeys.close),
  ViewKind.run: ('log my run', LogKeys.close),
  ViewKind.cardio: ('show my cardio log', LogKeys.close),
  ViewKind.wellbeing: ('show my sleep data', LogKeys.close),
  ViewKind.breathwork: ('start breathwork', BreathView.closeKey),
};

class Rig {
  Rig(this.t, {this.withLogs = true, this.breathStore, this.reduceMotion = true, this.realTimer = false});
  final WidgetTester t;
  final bool withLogs;
  final bool reduceMotion;

  /// The offer's own timer ([ViewOffer.timeout]) on the test's fake clock.
  final bool realTimer;
  final InMemoryStateStore? breathStore;
  final host = ViewHost();
  late final thread = ChatThread(store: InMemoryStateStore());
  late final offer = ViewOffer(
    host: host,
    post: thread.addOffer,
    resolved: (id, a) => thread.closeOffer(
        id, a == true ? OfferState.accepted : (a == false ? OfferState.declined : OfferState.closed)),
    timer: realTimer ? null : (d, f) => _NoTimer(),
    log: (_) {},
  );
  int offers = 0;

  Future<void> pump() async {
    phoneSurface(t, size: const Size(360, 800));
    final fog = FogSettings(InMemoryKeyValueStore());
    await fog.setEnabled(false);
    final speech = SpeechOutput(ThreadEngine(thread.addAssistant), log: (_) {});
    final c = AppController(
        fog: fog, server: FakeServerPort(), tts: SpeechOutputTts(speech), speech: speech, log: (_) {});
    c.turnRequests.listen(c.routeTurn);
    c.setupHook = offer.claim;
    final store = LogStore(InMemoryStateStore());
    await t.runAsync(() => store.add(fx.run));
    await t.pumpWidget(MediaQuery(
      data: MediaQueryData(size: const Size(360, 800), disableAnimations: reduceMotion),
      child: IllunisRoot(
        controller: c,
        chat: thread,
        views: host,
        logs: withLogs
            ? LogViews(
                store: store,
                server: FakeServerPort(),
                signals: () async => const [],
                clock: () => DateTime(2026, 10, 28, 9),
                log: (_) {},
              )
            : null,
        breath: BreathDeps(library: Future.value(lib), store: breathStore ?? InMemoryStateStore()),
        now: DateTime.utc(2026, 6, 21, 0),
        loadSkyShader: false,
        waterProgramLoader: () => Future.error(StateError('no shader in tests')),
        bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      ),
    ));
    await t.pump();
  }

  Future<void> settle() async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    await t.pump();
  }

  Future<void> send(String text) async {
    await t.enterText(find.byKey(ChatComposer.fieldKey), text);
    await t.tap(find.byKey(ChatComposer.sendKey));
    await settle();
  }

  Future<void> tap(Key key) async {
    await t.tap(find.byKey(key));
    await settle();
  }

  /// The composer is on screen and takes a tap: the sky is showing.
  bool get composerUsable => find.byKey(ChatComposer.fieldKey).hitTestable().evaluate().isNotEmpty;
}

const viewTypes = {
  LogsDayView, FoodView, ActivityView, StrengthView, RunView, CardioView, WellbeingView, BreathView, PlaceholderView,
};

Finder anyView() => find.byWidgetPredicate((w) => viewTypes.contains(w.runtimeType));

void main() {
  setUpAll(loadCaptionFonts);
  setUp(() => registerBreathNames(lib.names));
  tearDown(() => registerBreathNames(const []));

  testWidgets('every view: no view before the yes, opens on a tapped yes, Close returns to the sky', (t) async {
    final r = Rig(t);
    await r.pump();
    expect(r.composerUsable, isTrue);
    for (final MapEntry(key: kind, value: (phrase, close)) in views.entries) {
      await r.send(phrase);
      final id = r.offer.openOfferId;
      expect(id, isNotNull, reason: phrase);
      expect(find.text('Open ${kind.label}?'), findsOneWidget, reason: phrase);
      expect(r.host.current, isNull, reason: '$phrase: nothing opens before the yes');
      expect(find.byKey(close), findsNothing, reason: phrase);

      await r.tap(ValueKey('offer-$id-yes'));
      expect(r.host.current?.kind, kind, reason: phrase);
      expect(find.byKey(close), findsOneWidget, reason: phrase);
      expectFits(t, reason: phrase);
      if (kind != ViewKind.breathwork) {
        // A log view covers the sky and the composer while open.
        expect(r.composerUsable, isFalse, reason: phrase);
      }

      await r.tap(close);
      expect(r.host.current, isNull, reason: phrase);
      expect(find.byKey(close), findsNothing, reason: phrase);
      expect(r.composerUsable, isTrue, reason: '$phrase: back to the sky');
      expect(t.takeException(), isNull, reason: phrase);
    }
  });

  testWidgets('breathwork covers the composer during a session; Stop and Pause do not sit on it', (t) async {
    final store = InMemoryStateStore();
    await store.setString(breathProfileKey,
        const BreathProfile(advanced: false, cleared: {ScreenKind.standard}).encode());
    final r = Rig(t, breathStore: store);
    await r.pump();
    await r.send('do box breathing');
    await r.tap(ValueKey('offer-${r.offer.openOfferId}-yes'));
    await r.tap(BreathView.yesKey); // Start Box, fixed count now?
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(BreathView.stopKey), findsOneWidget);
    expect(r.composerUsable, isFalse);
    // A tap on Stop reaches Stop, not the composer under it.
    await t.tap(find.byKey(BreathView.stopKey));
    await t.pump();
    expect(find.text(lib.byId('box_breathing')!.copy.end), findsOneWidget);
    await r.tap(BreathView.closeKey);
    expect(r.composerUsable, isTrue);
  });

  testWidgets('a typed no, a new turn and a second yes open nothing', (t) async {
    final r = Rig(t);
    await r.pump();
    await r.send('show my food log');
    await r.send('no');
    expect(r.host.current, isNull);
    await r.send('show my food log');
    await r.send('Synthetic question about something else.');
    await r.send('yes');
    expect(r.host.current, isNull);
    expect(anyView(), findsNothing);
  });

  testWidgets('taps, a long press and swipes on the sky open no view and no menu', (t) async {
    final r = Rig(t);
    await r.pump();
    const centre = Offset(180, 300);
    await t.tapAt(centre);
    await t.pump();
    await t.longPressAt(centre);
    await t.pump();
    for (final d in [const Offset(0, -200), const Offset(0, 200), const Offset(-150, 0), const Offset(150, 0)]) {
      await t.dragFrom(centre, d);
      await t.pump();
    }
    expect(r.host.current, isNull);
    expect(r.offer.offerOpen, isFalse);
    expect(anyView(), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(PopupMenuButton), findsNothing);
    expect(r.composerUsable, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('a council offer is a question in the chat, not a view: its yes opens nothing', (t) async {
    final r = Rig(t);
    await r.pump();
    r.thread.addOffer('Want me to ask the council?', 'council-1');
    await t.pump();
    await r.tap(const ValueKey('offer-council-1-yes'));
    expect(r.host.current, isNull);
    expect(anyView(), findsNothing);
  });

  testWidgets('without log data a log request opens the placeholder after a yes, and it closes', (t) async {
    final r = Rig(t, withLogs: false);
    await r.pump();
    await r.send('show my run log');
    expect(find.byType(PlaceholderView), findsNothing);
    await r.tap(ValueKey('offer-${r.offer.openOfferId}-yes'));
    expect(find.byType(PlaceholderView), findsOneWidget);
    expect(find.text('Your run log'), findsOneWidget);
    expectFits(t);
    await r.tap(PlaceholderView.closeKey);
    expect(r.host.current, isNull);
    expect(r.composerUsable, isTrue);
  });

  testWidgets('Back closes the open view; the app stays on the sky', (t) async {
    final r = Rig(t);
    await r.pump();
    await r.send('show my food log');
    await r.tap(ValueKey('offer-${r.offer.openOfferId}-yes'));
    expect(r.host.current?.kind, ViewKind.food);
    expect(await t.binding.handlePopRoute(), isTrue);
    await r.settle();
    expect(r.host.current, isNull);
    expect(anyView(), findsNothing);
    expect(find.byType(IllunisRoot), findsOneWidget);
    expect(r.composerUsable, isTrue);
  });

  Finder viewOpacity() => find.ancestor(of: find.byType(PlaceholderView), matching: find.byType(Opacity)).first;

  testWidgets('a view rises in and is fully shown after Motion.viewIn', (t) async {
    final r = Rig(t, withLogs: false, reduceMotion: false);
    await r.pump();
    await r.send('show my run log');
    await r.tap(ValueKey('offer-${r.offer.openOfferId}-yes'));
    expect(t.widget<Opacity>(viewOpacity()).opacity, lessThan(1));
    await t.pump(Motion.viewIn);
    expect(t.widget<Opacity>(viewOpacity()).opacity, 1);
    // Closing: the view fades out and takes no touches meanwhile.
    await t.tap(find.byKey(PlaceholderView.closeKey));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(r.composerUsable, isTrue);
    await t.pump(Motion.viewOut);
    expect(anyView(), findsNothing);
  });

  testWidgets('with reduced motion a view shows in one frame', (t) async {
    final r = Rig(t, withLogs: false);
    await r.pump();
    await r.send('show my run log');
    await r.tap(ValueKey('offer-${r.offer.openOfferId}-yes'));
    expect(t.widget<Opacity>(viewOpacity()).opacity, 1);
    expect(find.text(PlaceholderView.text), findsOneWidget);
  });

  // The demo path, typed end to end in the real IllunisRoot at 360 px with
  // the real fonts: "do box breathing", the offer, a yes 40 s later, the
  // typed onboarding, then the session on the open sky.
  group('breathwork end to end, typed', () {
    Future<void> answer(WidgetTester t, String text) async {
      await t.enterText(find.byKey(BreathView.answerKey), text);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump();
    }

    Future<Rig> offered(WidgetTester t, InMemoryStateStore store) async {
      final r = Rig(t, breathStore: store, reduceMotion: false, realTimer: true);
      await r.pump();
      await r.send('do box breathing');
      expect(find.text('Open box breathing?'), findsOneWidget);
      expect(r.host.current, isNull);
      return r;
    }

    Future<void> openWithYes(WidgetTester t, Rig r) async {
      await r.send('yes');
      await t.pump(Motion.viewIn);
      expect(find.byType(BreathView), findsOneWidget);
    }

    String status(WidgetTester t) => t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .firstWhere((s) => s.endsWith(' left') || s.startsWith('Getting ready') || s.startsWith('Paused.'));

    testWidgets('offer, a yes after 40 s, the typed onboarding, then the session; Pause, Stop and Close',
        (t) async {
      final store = InMemoryStateStore();
      final r = await offered(t, store);
      await t.pump(const Duration(seconds: 40));
      expect(r.offer.offerOpen, isTrue, reason: 'still open at 40 s');
      await openWithYes(t, r);
      expect(r.thread.entries.firstWhere((e) => e.offer != null).offer!.state, OfferState.accepted);

      // One question a screen; typed answers; "not sure" asks again.
      expect(find.text(introText), findsOneWidget);
      expectFits(t, reason: 'intro');
      await answer(t, 'yes');
      expect(find.text(howText), findsOneWidget);
      expectFits(t, reason: 'how');
      await answer(t, 'yes');
      expect(find.text(screenQuestion), findsOneWidget);
      await answer(t, 'not sure');
      expect(find.text(screenQuestion), findsOneWidget);
      expect(find.text(BreathView.missText), findsOneWidget);
      expectFits(t, reason: 'screen, missed');
      await answer(t, 'no');
      expect(find.text(advancedQuestion), findsOneWidget);
      expect(find.text(BreathView.missText), findsNothing);
      await answer(t, 'not sure');
      expect(find.text(advancedQuestion), findsOneWidget);
      expect(find.text(BreathView.missText), findsOneWidget);
      expectFits(t, reason: 'advanced, missed');
      await answer(t, 'no');
      expect(find.text('Start Box, fixed count now?'), findsOneWidget);
      expect(find.byKey(BreathView.visualKey), findsNothing);
      expectFits(t, reason: 'start');
      final saved = BreathProfile.decode(await store.getString(breathProfileKey))!;
      expect(saved.advanced, isFalse);
      expect(saved.cleared, {ScreenKind.standard});

      // The session: count-in, then the phases and the countdown.
      await answer(t, 'yes');
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(BreathView.visualKey), findsOneWidget);
      expect(status(t), 'Getting ready: breath 1 of 3');
      expect(r.composerUsable, isFalse);

      final sky = t.getRect(find.byKey(BreathView.skyKey));
      final ring = t.getRect(find.byKey(BreathView.visualKey));
      final close = t.getRect(find.byKey(BreathView.closeKey));
      expect((ring.center.dx - 180).abs(), lessThan(0.5), reason: 'ring centred across');
      expect((ring.center.dy - sky.center.dy).abs(), lessThan(0.5), reason: 'ring centred in the sky');
      expect(ring.overlaps(close), isFalse);
      expect(sky.top, greaterThanOrEqualTo(close.bottom));
      expectFits(t, reason: 'count-in');

      await t.pump(const Duration(seconds: 48)); // 3 x 16 s count-in
      await t.pump(const Duration(milliseconds: 100));
      expect(status(t), '5:00 left');
      expect(find.text('Breathe in'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      expect(find.text('Pause, if comfortable'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      expect(find.text('Breathe out'), findsOneWidget);
      expect(status(t), '4:52 left');
      expect(t.getRect(find.byKey(BreathView.visualKey)), ring, reason: 'the ring keeps its place');
      expectFits(t, reason: 'running');

      // Pause holds the clock; Resume carries on.
      await r.tap(BreathView.pauseKey);
      expect(find.text('Resume'), findsOneWidget);
      expect(status(t), 'Paused. 4:52 left');
      await t.pump(const Duration(seconds: 5));
      expect(status(t), 'Paused. 4:52 left');
      await r.tap(BreathView.pauseKey);
      expect(find.text('Pause'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(status(t), '4:50 left');

      // Stop ends at once with the end copy; Close returns to the sky.
      await r.tap(BreathView.stopKey);
      expect(find.text(lib.byId('box_breathing')!.copy.end), findsOneWidget);
      expect(find.byKey(BreathView.visualKey), findsNothing);
      expectFits(t, reason: 'end');
      await r.tap(BreathView.closeKey);
      await t.pump(Motion.viewOut);
      await t.pump(const Duration(milliseconds: 16)); // the fade's last frame
      expect(r.host.current, isNull);
      expect(find.byType(BreathView), findsNothing);
      expect(r.composerUsable, isTrue);
      expect(t.takeException(), isNull);
    });

    testWidgets('Close mid-session ends it and returns to the sky', (t) async {
      final store = InMemoryStateStore();
      await store.setString(breathProfileKey,
          const BreathProfile(advanced: false, cleared: {ScreenKind.standard}).encode());
      final r = await offered(t, store);
      await openWithYes(t, r);
      await answer(t, 'yes'); // Start Box, fixed count now?
      await t.pump(const Duration(seconds: 52));
      expect(find.byKey(BreathView.visualKey), findsOneWidget);
      await r.tap(BreathView.closeKey);
      await t.pump(Motion.viewOut);
      await t.pump(const Duration(milliseconds: 16)); // the fade's last frame
      expect(r.host.current, isNull);
      expect(find.byType(BreathView), findsNothing);
      expect(r.composerUsable, isTrue);
      await t.pump(const Duration(seconds: 10));
      expect(t.takeException(), isNull);
    });

    testWidgets('a typed yes on the default screen shows the clinician notice and no session', (t) async {
      final store = InMemoryStateStore();
      final r = await offered(t, store);
      await openWithYes(t, r);
      await answer(t, 'yes'); // intro
      await answer(t, 'yes'); // how
      expect(find.text(screenQuestion), findsOneWidget);
      await answer(t, 'yes'); // screen: yes
      expect(find.text('This session will not start.'), findsOneWidget);
      expect(find.text(lib.byId('box_breathing')!.copy.notice), findsOneWidget);
      expect(find.byKey(BreathView.yesKey), findsNothing);
      expect(find.byKey(BreathView.visualKey), findsNothing);
      expect(await store.getString(breathProfileKey), isNull, reason: 'nothing stored');
      expectFits(t, reason: 'notice');
      await r.tap(BreathView.closeKey);
      await t.pump(Motion.viewOut);
      await t.pump(const Duration(milliseconds: 16)); // the fade's last frame
      expect(r.host.current, isNull);
      expect(r.composerUsable, isTrue);
    });

    testWidgets('a no to the offer opens nothing; 90 s without an answer closes it', (t) async {
      final r = await offered(t, InMemoryStateStore());
      await r.send('no');
      expect(r.host.current, isNull);
      expect(r.thread.entries.firstWhere((e) => e.offer != null).offer!.state, OfferState.declined);

      await r.send('do box breathing');
      await t.pump(const Duration(seconds: 89));
      expect(r.offer.offerOpen, isTrue);
      await t.pump(const Duration(seconds: 1));
      expect(r.offer.offerOpen, isFalse);
      expect(r.thread.entries.lastWhere((e) => e.offer != null).offer!.state, OfferState.closed);
      await r.send('yes');
      expect(r.host.current, isNull);
      expect(find.byType(BreathView), findsNothing);
    });
  });
}
