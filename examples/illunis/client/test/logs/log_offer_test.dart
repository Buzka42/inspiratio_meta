// Ask first (PLAN.md rule 2026-10-28): no log view opens without a yes; a no,
// a timeout or a new turn cancels the offer. Synthetic text only.
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
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/logs/log_store.dart';
import 'package:illunis_client/logs/views/activity_view.dart';
import 'package:illunis_client/logs/views/cardio_view.dart';
import 'package:illunis_client/logs/views/day_view.dart';
import 'package:illunis_client/logs/views/food_view.dart';
import 'package:illunis_client/logs/views/log_views.dart';
import 'package:illunis_client/logs/views/run_view.dart';
import 'package:illunis_client/logs/views/strength_view.dart';
import 'package:illunis_client/logs/views/wellbeing_view.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/thread_engine.dart';
import 'package:illunis_client/widgets/chat_composer.dart';

class FakeTimer implements Timer {
  FakeTimer(this.f);
  final void Function() f;
  bool cancelled = false;
  void fire() {
    if (!cancelled) f();
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

const requests = {
  'log my run': ViewKind.run,
  'show my food log': ViewKind.food,
  'open my activity log': ViewKind.activity,
  'log a strength session': ViewKind.strength,
  'show my cardio log': ViewKind.cardio,
  'show my sleep data': ViewKind.wellbeing,
  'show my logs': ViewKind.logs,
};

const viewTypes = {
  ViewKind.run: RunView,
  ViewKind.food: FoodView,
  ViewKind.activity: ActivityView,
  ViewKind.strength: StrengthView,
  ViewKind.cardio: CardioView,
  ViewKind.wellbeing: WellbeingView,
  ViewKind.logs: LogsDayView,
};

class Rig {
  Rig(this.t);
  final WidgetTester t;
  final timers = <FakeTimer>[];
  final views = ViewHost();
  late final thread = ChatThread(store: InMemoryStateStore());
  late final offer = ViewOffer(
    host: views,
    post: thread.addOffer,
    resolved: (id, a) => thread.closeOffer(
        id, a == true ? OfferState.accepted : (a == false ? OfferState.declined : OfferState.closed)),
    timer: (d, f) {
      final t = FakeTimer(f);
      timers.add(t);
      return t;
    },
    log: (_) {},
  );

  Future<void> pump() async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fog = FogSettings(InMemoryKeyValueStore());
    await fog.setEnabled(false);
    final speech = SpeechOutput(ThreadEngine(thread.addAssistant), log: (_) {});
    final c = AppController(
        fog: fog, server: FakeServerPort(), tts: SpeechOutputTts(speech), speech: speech, log: (_) {});
    c.turnRequests.listen(c.routeTurn);
    c.setupHook = offer.claim;
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(360, 800), disableAnimations: true),
      child: IllunisRoot(
        controller: c,
        chat: thread,
        views: views,
        logs: LogViews(
          store: LogStore(InMemoryStateStore()),
          server: FakeServerPort(),
          signals: () async => const [],
          clock: () => DateTime(2026, 10, 28, 9),
          log: (_) {},
        ),
        now: DateTime.utc(2026, 6, 21, 0),
        loadSkyShader: false,
        waterProgramLoader: () => Future.error(StateError('no shader in tests')),
        bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
      ),
    ));
    await t.pump();
  }

  Future<void> send(String text) async {
    await t.enterText(find.byKey(ChatComposer.fieldKey), text);
    await t.tap(find.byKey(ChatComposer.sendKey));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }

  Future<void> tap(Key key) async {
    await t.tap(find.byKey(key));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

Finder anyLogView() => find.byWidgetPredicate((w) => viewTypes.values.contains(w.runtimeType));

void main() {
  test('each log request is matched by plain code and only offers', () {
    for (final MapEntry(key: text, value: kind) in requests.entries) {
      expect(parseViewRequest(text)?.kind, kind, reason: text);
    }
    for (final t in ['how do I log my run', 'log my run 5 km in 26 min', 'logs', 'show my view', 'run']) {
      expect(parseViewRequest(t), isNull, reason: t);
    }
  });

  testWidgets('every log view opens only after a tapped yes', (t) async {
    final r = Rig(t);
    await r.pump();
    var n = 0;
    for (final MapEntry(key: text, value: kind) in requests.entries) {
      n++;
      await r.send(text);
      expect(find.text('Open ${kind.label}?'), findsOneWidget, reason: text);
      expect(anyLogView(), findsNothing, reason: text);
      expect(r.views.current, isNull);
      await r.tap(ValueKey('offer-view-$n-yes'));
      expect(find.byType(viewTypes[kind]!), findsOneWidget, reason: text);
      expect(t.takeException(), isNull, reason: text);
      r.views.close();
      await t.pump();
      expect(anyLogView(), findsNothing);
    }
  });

  testWidgets('a typed yes opens the log view; a typed no does not', (t) async {
    final r = Rig(t);
    await r.pump();
    await r.send('log my run');
    await r.send('no');
    expect(anyLogView(), findsNothing);
    expect(r.views.current, isNull);
    await r.send('log my run');
    await r.send('yes');
    expect(find.byType(RunView), findsOneWidget);
  });

  testWidgets('a tapped no leaves the view closed', (t) async {
    final r = Rig(t);
    await r.pump();
    await r.send('show my strength log');
    await r.tap(const ValueKey('offer-view-1-no'));
    expect(anyLogView(), findsNothing);
    expect(r.thread.entries.firstWhere((e) => e.offer != null).offer!.state, OfferState.declined);
  });

  testWidgets('a timeout cancels the offer; a late yes opens nothing', (t) async {
    final r = Rig(t);
    await r.pump();
    await r.send('show my cardio log');
    r.timers.single.fire();
    await t.pump();
    expect(r.offer.offerOpen, isFalse);
    expect(find.byKey(const ValueKey('offer-view-1-yes')), findsNothing);
    await r.send('yes');
    expect(anyLogView(), findsNothing);
    expect(r.views.current, isNull);
  });

  testWidgets('a new turn cancels the offer', (t) async {
    final r = Rig(t);
    await r.pump();
    await r.send('show my food log');
    await r.send('Synthetic question.');
    expect(r.offer.offerOpen, isFalse);
    await r.send('yes');
    expect(anyLogView(), findsNothing);
  });

  test('one yes opens once; after close, a second yes opens nothing', () {
    final host = ViewHost();
    final offer = ViewOffer(host: host, post: (_, _) {}, timer: (d, f) => FakeTimer(f), log: (_) {});
    offer.claim('log my run');
    expect(host.current, isNull);
    expect(offer.claim('yes'), isTrue);
    expect(host.current?.kind, ViewKind.run);
    host.close();
    expect(offer.claim('yes'), isFalse);
    expect(host.current, isNull);
  });
}
