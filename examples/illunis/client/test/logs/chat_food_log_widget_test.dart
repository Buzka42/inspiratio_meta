// The demo path end to end on the app's own widgets: a meal typed in the
// chat shows the log preview with Save? (no view opens and no chat reply is
// asked for), a tapped yes saves it, and the food view (opened after its
// own yes) lists the entry with its calories and total. A mismatch shows
// both numbers as the choice and saves nothing until the pick and the yes.
// Synthetic data only.
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
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/logs/chat_food_log.dart';
import 'package:illunis_client/logs/log_capture.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_store.dart';
import 'package:illunis_client/logs/views/food_view.dart';
import 'package:illunis_client/logs/views/log_frame.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/thread_engine.dart';
import 'package:illunis_client/widgets/chat_composer.dart';

import 'chat_food_log_test.dart' show mealLine, riceAndEggs, riceChoice, riceMismatch;

// The clock's day, so the food view opens on the day the entry was saved.
const today = '2026-10-28';

Map<String, dynamic> onToday(Map<String, Object?> env) => Map<String, dynamic>.from(env)..['date'] = today;

class Rig {
  Rig(this.t, LogParseResult result) {
    server.logParseResult = result;
  }
  final WidgetTester t;
  final server = FakeServerPort();
  final views = ViewHost();
  final store = LogStore(InMemoryStateStore());
  late final thread = ChatThread(store: InMemoryStateStore());
  late final offer = ViewOffer(
    host: views,
    post: thread.addOffer,
    resolved: (id, a) => thread.closeOffer(id, a == true ? OfferState.accepted : (a == false ? OfferState.declined : OfferState.closed)),
    timer: (d, f) => _NoTimer(),
    log: (_) {},
  );
  late final food = ChatFoodLog(
    capture: LogCapture(kind: LogKind.food, server: server, store: store, date: () => today, log: (_) {}),
    chat: ChatLogPort(
      say: thread.addAssistant,
      ask: thread.addOffer,
      close: (id, a) => thread.closeOffer(id, a == true ? OfferState.accepted : (a == false ? OfferState.declined : OfferState.closed)),
      note: thread.attachSources,
    ),
    log: (_) {},
  );

  Future<void> pump() async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fog = FogSettings(InMemoryKeyValueStore());
    await fog.setEnabled(false);
    final speech = SpeechOutput(ThreadEngine(thread.addAssistant), log: (_) {});
    final c = AppController(fog: fog, server: server, tts: SpeechOutputTts(speech), speech: speech, log: (_) {});
    c.turnRequests.listen(c.routeTurn);
    // As main.dart: the meal line first (it cancels a view offer), then the view offer.
    c.setupHook = (text) {
      if (food.claim(text)) {
        offer.cancel();
        return true;
      }
      return offer.claim(text);
    };
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(360, 800), disableAnimations: true),
      child: IllunisRoot(
        controller: c,
        chat: thread,
        views: views,
        logs: LogViews(
          store: store,
          server: server,
          signals: () async => const [],
          clock: () => DateTime(2026, 10, 28, 13),
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

  Future<void> settle() async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }

  Future<void> send(String text) async {
    await t.enterText(find.byKey(ChatComposer.fieldKey), text);
    await t.tap(find.byKey(ChatComposer.sendKey));
    await settle();
  }

  Future<void> tap(String key) async {
    await t.tap(find.byKey(ValueKey(key)));
    await settle();
  }

  Future<List<LogEntry>> get saved => store.forDay(LogKind.food, today);
}

class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

void main() {
  testWidgets('typed meal: preview with Save?, tapped yes saves, the food view lists it with its total', (t) async {
    final r = Rig(t, LogParseResult.parsed(onToday(riceAndEggs)));
    await r.pump();
    await r.send(mealLine);

    expect(find.textContaining('Cooked rice · 200 g · 260 kcal est.'), findsOneWidget);
    expect(find.textContaining('Eggs · 2 pieces · 144 kcal est.'), findsOneWidget);
    expect(find.textContaining('Total: 2 items · 2 estimated (404 kcal)'), findsOneWidget);
    expect(find.text('Save?'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-log-1-yes')), findsOneWidget);
    // Logged, not answered, and no view opened.
    expect(r.server.calls, ['/log/parse']);
    expect(r.views.current, isNull);
    expect(find.byType(FoodView), findsNothing);
    expect(await r.saved, isEmpty);

    await r.tap('offer-log-1-yes');
    expect(find.text(ChatLogText.saved), findsOneWidget);
    expect((await r.saved).single, isA<FoodEntry>());
    expect(r.views.current, isNull);

    // Seeing the log is its own offer.
    await r.send('show my food log');
    expect(find.text('Open your food log?'), findsOneWidget);
    await r.tap('offer-view-1-yes');
    expect(find.byType(FoodView), findsOneWidget);
    await r.settle(); // the view reads the store
    expect(find.text('cooked rice'), findsOneWidget);
    expect(find.text('200 g · 260 kcal est.'), findsOneWidget);
    expect(find.text('2 pieces · 144 kcal est.'), findsOneWidget);
    final total = t.widget<Text>(find.descendant(of: find.byKey(LogKeys.total), matching: find.byType(Text)));
    expect(total.textSpan!.toPlainText(), '2 items · 2 estimated (404 kcal)');
    expect(t.takeException(), isNull);
  });

  testWidgets('typed yes saves; typed no saves nothing', (t) async {
    final r = Rig(t, LogParseResult.parsed(onToday(riceAndEggs)));
    await r.pump();
    await r.send(mealLine);
    await r.send('no');
    expect(find.text(CaptureText.discarded), findsOneWidget);
    expect(await r.saved, isEmpty);
    await r.send(mealLine);
    await r.send('yes');
    expect(find.text(ChatLogText.saved), findsOneWidget);
    expect(await r.saved, hasLength(1));
  });

  testWidgets('mismatch: both numbers and the choice, nothing saved until the pick and the yes', (t) async {
    final r = Rig(t, LogParseResult.choice(onToday(riceMismatch), [riceChoice]));
    await r.pump();
    await r.send('I had 200 g cooked rice 400 kcal and two eggs for lunch');

    expect(find.textContaining('Cooked rice: you wrote 400 kcal. Synthetic Rice lists 270 kcal.'), findsOneWidget);
    expect(find.text('Keep mine (400)'), findsOneWidget);
    expect(find.text('Use 270'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-log-1-yes')), findsNothing);
    expect(await r.saved, isEmpty);

    await r.tap('offer-log-1-1');
    expect(find.textContaining('Cooked rice · 200 g · 270 kcal est.'), findsOneWidget);
    expect(find.text('Save?'), findsOneWidget);
    expect(await r.saved, isEmpty);

    await r.tap('offer-log-2-yes');
    final item = ((await r.saved).single as FoodEntry).items.first;
    expect((item.kcal, item.estimated), (270, true));
    expect(t.takeException(), isNull);
  });

  testWidgets('a chat question still goes to the reply, not the log', (t) async {
    final r = Rig(t, LogParseResult.parsed(onToday(riceAndEggs)));
    await r.pump();
    await r.send('I had a headache this morning');
    expect(r.server.calls, isNot(contains('/log/parse')));
    expect(find.text('Save?'), findsNothing);
  });
}
