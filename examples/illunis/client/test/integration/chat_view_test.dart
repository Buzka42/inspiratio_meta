// The text chat on the main view: the composer shows with fog off, a typed
// turn fills the thread, and a view opens only after a yes (typed or
// tapped). Synthetic text only; this checks the widget tree, not the look.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/breath/breath_view.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/illunis_root.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/council_flow.dart' show notMedicalAdviceLine;
import 'package:illunis_client/app/view_offer.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/thread_engine.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';
import 'package:illunis_client/widgets/chat_composer.dart';
import 'package:illunis_client/widgets/glass/glass_actions.dart';
import 'package:illunis_client/widgets/glass/glass_surface.dart';

import '../app/view_audit_helpers.dart';

Future<(AppController, ChatThread, ViewHost)> pumpChat(WidgetTester t, {bool reduceMotion = false}) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fogStore = InMemoryKeyValueStore();
  final fog = FogSettings(fogStore);
  await fog.setEnabled(false);
  final thread = ChatThread(store: InMemoryStateStore());
  final speech = SpeechOutput(ThreadEngine(thread.addAssistant), log: (_) {});
  final c = AppController(
      fog: fog, server: FakeServerPort(), tts: SpeechOutputTts(speech), speech: speech, log: (_) {});
  c.turnRequests.listen(c.routeTurn);
  final views = ViewHost();
  final offer = ViewOffer(
    host: views,
    post: thread.addOffer,
    resolved: (id, a) => thread.closeOffer(
        id, a == true ? OfferState.accepted : (a == false ? OfferState.declined : OfferState.closed)),
    log: (_) {},
  );
  c.setupHook = offer.claim;
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(size: const Size(360, 800), disableAnimations: reduceMotion),
    child: IllunisRoot(
      controller: c,
      chat: thread,
      views: views,
      now: DateTime.utc(2026, 6, 21, 0),
      loadSkyShader: false,
      waterProgramLoader: () => Future.error(StateError('no shader in tests')),
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
    ),
  ));
  await t.pump();
  return (c, thread, views);
}

Future<void> typeAndSend(WidgetTester t, String text) async {
  await t.enterText(find.byKey(ChatComposer.fieldKey), text);
  await t.tap(find.byKey(ChatComposer.sendKey));
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await t.pump();
}

void main() {
  // The real fonts, so the fit ladder measures as on the phone.
  setUpAll(loadCaptionFonts);

  testWidgets('the composer shows with fog off and a typed turn shows both lines', (t) async {
    final (c, thread, _) = await pumpChat(t);
    expect(c.fogEnabled, isFalse);
    expect(find.byType(ChatComposer), findsOneWidget);
    expect(find.text(ChatComposer.hint), findsOneWidget);

    await typeAndSend(t, 'Synthetic question.');
    expect(thread.entries.map((e) => e.role), [ChatRole.user, ChatRole.assistant]);
    expect(find.descendant(of: find.byType(ChatComposer), matching: find.text('Synthetic question.')),
        findsOneWidget);
    expect(find.descendant(of: find.byType(ChatComposer), matching: find.text('Synthetic reply.')),
        findsOneWidget);
    // With fog off the caption also shows (static).
    expect(c.caption, 'Synthetic reply.');
    expect(t.takeException(), isNull);
  });

  testWidgets('a view opens only after a tapped yes; no leaves it closed', (t) async {
    final (_, thread, views) = await pumpChat(t, reduceMotion: true);
    await typeAndSend(t, 'show my logs');
    expect(find.text('Open your logs?'), findsOneWidget);
    expect(find.byType(PlaceholderView), findsNothing);
    expect(views.current, isNull);

    await t.tap(find.byKey(const ValueKey('offer-view-1-no')));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(find.byType(PlaceholderView), findsNothing);
    expect(thread.entries.firstWhere((e) => e.offer != null).offer!.state, OfferState.declined);

    await typeAndSend(t, 'start breathwork');
    await t.tap(find.byKey(const ValueKey('offer-view-2-yes')));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    expect(find.byType(BreathView), findsOneWidget);
  });

  testWidgets('a typed yes opens the offered view', (t) async {
    final (_, _, views) = await pumpChat(t);
    await typeAndSend(t, 'open the strength log');
    expect(views.current, isNull);
    await typeAndSend(t, 'yes');
    expect(views.current?.label, 'your strength log');
    expect(find.text('Your strength log'), findsOneWidget);
  });

  testWidgets('the composer fits a phone width with 16 px gutters', (t) async {
    await pumpChat(t);
    final field = t.getRect(find.byKey(ChatComposer.fieldKey));
    final send = t.getRect(find.byKey(ChatComposer.sendKey));
    expect(field.left, greaterThanOrEqualTo(ChatComposer.gutter));
    expect(send.right, lessThanOrEqualTo(360 - ChatComposer.gutter));
  });

  testWidgets('two voices: the reply in the serif, your line and the hint in the sans, all inverse-colour', (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final thread = ChatThread()
      ..addUser('Synthetic question?')
      ..addAssistant('Synthetic reply.');
    await t.pumpWidget(MaterialApp(
        home: Stack(children: [Positioned.fill(child: ChatComposer(thread: thread, onSubmit: (_) {}))])));
    await t.pump();
    final p = Palette.night;
    final reply = t.widget<Text>(find.text('Synthetic reply.')).style!;
    expect((reply.fontFamily, TypeScale.isInverse(reply)), (Fonts.serif, true));
    final echo = t.widget<Text>(find.text('Synthetic question?')).style!;
    expect((echo.fontFamily, TypeScale.isInverse(echo)), (Fonts.sans, true));
    final hint = t.widget<Text>(find.text(ChatComposer.hint)).style!;
    expect((hint.fontFamily, TypeScale.isInverse(hint)), (Fonts.sans, true));
    final typed = t.widget<EditableText>(find.byType(EditableText)).style;
    expect((typed.fontFamily, TypeScale.isInverse(typed)), (Fonts.sans, true));
    // No SkyLight here: no plate (since 2026-10-29), and with no look at
    // the sky the text carries the full halo (test/ui/halo_test.dart checks
    // what it does over the sky sampled on the phone).
    expect(t.state<GlassPanelState>(find.byType(GlassPanel).first).halo, Halo.unknown);
    final shown = t.renderObject<RenderParagraph>(find.text('Synthetic reply.')).text.style!;
    expect(shown.shadows, Halo.shadows(p.halo, Halo.unknown));
  });

  testWidgets('by day the composer takes the day inks from SkyLight', (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final thread = ChatThread()..addAssistant('Synthetic reply.');
    await t.pumpWidget(MaterialApp(
        home: SkyLight(
            daylight: 1,
            palette: Palette.day,
            child: Stack(children: [Positioned.fill(child: ChatComposer(thread: thread, onSubmit: (_) {}))]))));
    await t.pump();
    // The text is inverse-colour; the day palette shows in the halo and
    // the cursor.
    for (final s in ['Synthetic reply.', ChatComposer.hint]) {
      final style = t.renderObject<RenderParagraph>(find.text(s)).text.style!;
      expect(TypeScale.isInverse(style), isTrue, reason: s);
    }
    final reply = t.renderObject<RenderParagraph>(find.text('Synthetic reply.')).text.style!;
    expect(reply.shadows!.first.color.withValues(alpha: 1), Palette.day.halo.withValues(alpha: 1));
    expect(t.widget<EditableText>(find.byType(EditableText)).cursorColor, Palette.day.accent);
  });

  group('the reply fits without scrolling or clipping', () {
    const question = 'Synthetic question about sleep?';
    const sources = 'Sources: Synthetic Passage A · Synthetic Passage B';
    final long = [
      for (var i = 1; i <= 14; i++) 'Synthetic sentence $i about rest, water and a short walk after lunch.',
      'This is not medical advice.',
    ].join(' ');
    String words(int n) =>
        List.generate(n, (i) => ['quiet', 'water', 'after', 'walking', 'rest', 'evening', 'light', 'and'][i % 8]).join(' ');

    Future<ChatThread> pumpComposer(WidgetTester t, String reply,
        {double keyboard = 0, Size size = const Size(360, 800), String? replySources = sources}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final thread = ChatThread()
        ..addUser(question)
        ..addAssistant(reply);
      if (replySources != null) thread.attachSources(replySources);
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(size: size, viewInsets: EdgeInsets.only(bottom: keyboard), disableAnimations: true),
        child: MaterialApp(
          home: Stack(children: [Positioned.fill(child: ChatComposer(thread: thread, onSubmit: (_) {}))]),
        ),
      ));
      await t.pump();
      return thread;
    }

    /// Every [texts] shows whole, above the field, on screen, not in a
    /// scroll view. Your own line may have been dropped, never cut.
    void expectFits(WidgetTester t, List<String> texts, {double keyboard = 0, double height = 800}) {
      expect(t.takeException(), isNull, reason: 'no RenderFlex overflow');
      final field = t.getRect(find.byKey(ChatComposer.fieldKey));
      expect(field.bottom, lessThanOrEqualTo(height - keyboard));
      for (final text in [...texts, if (find.text(question).evaluate().isNotEmpty) question]) {
        expect(find.text(text), findsOneWidget, reason: text);
        final r = t.getRect(find.text(text));
        expect(r.top, greaterThanOrEqualTo(0), reason: text);
        expect(r.left, greaterThanOrEqualTo(0), reason: text);
        expect(r.right, lessThanOrEqualTo(360), reason: text);
        expect(r.bottom, lessThanOrEqualTo(field.top), reason: text);
        expect(find.ancestor(of: find.text(text), matching: find.byType(Scrollable)), findsNothing, reason: text);
      }
    }

    double fontOf(WidgetTester t, String text) => t.widget<Text>(find.text(text)).style!.fontSize!;

    /// The glass is drawn at its laid-out size: the scale-down guard is idle.
    void expectUnscaled(WidgetTester t) {
      final glass = find.byType(GlassPanel).first;
      expect(t.getRect(glass).height, closeTo(t.getSize(glass).height, 0.5));
    }

    testWidgets('a short reply renders at 22 px and sits mid-sky', (t) async {
      await pumpComposer(t, 'Synthetic reply.');
      expectFits(t, ['Synthetic reply.', sources]);
      expect(fontOf(t, 'Synthetic reply.'), 22);
      expect(find.text(question), findsOneWidget);
      final r = t.getRect(find.text('Synthetic reply.'));
      final field = t.getRect(find.byKey(ChatComposer.fieldKey));
      expect(r.center.dy, closeTo(field.top / 2, field.top * 0.2));
    });

    testWidgets('a long reply at 360 px steps its font down and fits', (t) async {
      await pumpComposer(t, long);
      expectFits(t, [long, sources]);
      expect(fontOf(t, long), lessThan(22));
      expect(fontOf(t, long), greaterThanOrEqualTo(TypeScale.replyFloor));
    });

    testWidgets('a 120-word reply with sources and the disclaimer fits 360 x 780 at 18 px, unscaled', (t) async {
      final reply = words(120);
      await pumpComposer(t, '$reply $notMedicalAdviceLine', size: const Size(360, 780));
      expectFits(t, [reply, sources, notMedicalAdviceLine], height: 780);
      expect(fontOf(t, reply), greaterThanOrEqualTo(18));
      expectUnscaled(t);
    });

    // 66 words: past what fits with your line at 18 px in Newsreader (60 did
    // in Cormorant), short of the scale-down guard (76).
    testWidgets('a 66-word reply with sources and a 320 px keyboard fits at 18 px, your line dropped', (t) async {
      final reply = words(66);
      await pumpComposer(t, reply, keyboard: 320, size: const Size(360, 780));
      expectFits(t, [reply, sources], keyboard: 320, height: 780);
      expect(fontOf(t, reply), 18);
      expect(find.text(question), findsNothing);
      expectUnscaled(t);
    });

    testWidgets('the disclaimer is its own note line, not part of the reply', (t) async {
      await pumpComposer(t, 'Synthetic answer. $notMedicalAdviceLine');
      expect(find.text('Synthetic answer.'), findsOneWidget);
      final note = t.widget<Text>(find.text(notMedicalAdviceLine)).style!;
      expect((note.fontFamily, note.fontSize), (Fonts.sans, TypeScale.note(Palette.night.ink2).fontSize));
      expect(t.widget<Text>(find.text(sources)).style!.fontSize, note.fontSize);
    });

    testWidgets('a streamed reply never grows its font, even when room comes back', (t) async {
      t.view.physicalSize = const Size(360, 780);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final thread = ChatThread()..addUser(question);
      var keyboard = 320.0;
      Widget app() => MediaQuery(
            data: MediaQueryData(
                size: const Size(360, 780), viewInsets: EdgeInsets.only(bottom: keyboard), disableAnimations: true),
            child: MaterialApp(
                home: Stack(children: [Positioned.fill(child: ChatComposer(thread: thread, onSubmit: (_) {}))])),
          );
      await t.pumpWidget(app());
      final sizes = <double>[];
      for (var i = 0; i < 30; i++) {
        thread.addAssistant('Synthetic sentence $i about rest and water.');
        if (i == 20) {
          keyboard = 0; // the keyboard closes mid-reply
          await t.pumpWidget(app());
        }
        await t.pump();
        final text = thread.entries.last.text;
        sizes.add(fontOf(t, text));
      }
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], lessThanOrEqualTo(sizes[i - 1]), reason: 'token $i: $sizes');
      }
      expect(sizes.first, 22);
      expect(sizes.last, lessThan(22));
    });

    testWidgets('a long reply still fits with the keyboard open', (t) async {
      await pumpComposer(t, long, keyboard: 320);
      expectFits(t, [long, sources], keyboard: 320);
    });

    testWidgets('a very long reply is scaled, never clipped', (t) async {
      final huge = List.filled(4, long).join(' ');
      await pumpComposer(t, huge, keyboard: 320);
      expectFits(t, [huge, sources], keyboard: 320);
    });

    testWidgets('an offer: Yes and No form the glass\'s bottom edge, no glass of their own, and submit', (t) async {
      final said = <String>[];
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final thread = ChatThread()..addOffer('Open your logs?', 'v1');
      await t.pumpWidget(MaterialApp(
          home: Stack(children: [Positioned.fill(child: ChatComposer(thread: thread, onSubmit: said.add))])));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(GlassActions), findsOneWidget);
      final glass = t.getRect(find.ancestor(of: find.byType(GlassActions), matching: find.byType(GlassPanel)));
      expect(t.getRect(find.byType(GlassActions)).bottom, closeTo(glass.bottom, 0.5));
      for (final k in ['yes', 'no']) {
        final b = find.byKey(ValueKey('offer-v1-$k'));
        expect(find.descendant(of: b, matching: find.byType(GlassPanel)), findsNothing);
        expect(find.ancestor(of: b, matching: find.byType(Scrollable)), findsNothing);
        final size = t.getSize(b);
        expect(size.height, greaterThanOrEqualTo(48));
        await t.tap(b);
      }
      expect(said, ['Yes', 'No']);
    });

    testWidgets('sending closes the keyboard so the reply gets the sky', (t) async {
      await pumpComposer(t, 'Synthetic reply.');
      await t.tap(find.byKey(ChatComposer.fieldKey));
      await t.pump();
      expect(t.testTextInput.isVisible, isTrue);
      await t.enterText(find.byKey(ChatComposer.fieldKey), 'Synthetic line');
      await t.tap(find.byKey(ChatComposer.sendKey));
      await t.pump();
      expect(t.testTextInput.isVisible, isFalse);
    });
  });
}
