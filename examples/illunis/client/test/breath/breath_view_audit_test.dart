// Audit of the breathwork view at phone width (360 px) with the real fonts:
// every step (onboarding questions, the typed choice and the library list,
// notices, Start, the session, the end) fits with no overflow or clipped
// text, also at 1.5x text; the empty library and a failed load are readable;
// Close returns to the sky. Opened only through ViewHost after a yes.
// Synthetic store, silent voice.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/view_offer.dart';
import 'package:illunis_client/app/view_requests.dart';
import 'package:illunis_client/breath/breath_library.dart';
import 'package:illunis_client/breath/breath_onboarding.dart';
import 'package:illunis_client/breath/breath_view.dart';
import 'package:illunis_client/breath/breath_wiring.dart';
import 'package:illunis_client/breath/technique.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';
import 'package:illunis_client/widgets/glass/glass_actions.dart';
import 'package:illunis_client/widgets/glass/glass_sheet.dart';
import 'package:illunis_client/widgets/glass/glass_surface.dart';

import '../app/view_audit_helpers.dart';
import 'breath_fixtures.dart';

final lib = loadAssetLibrary();

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
              final v? when v.kind == ViewKind.breathwork => BreathView(request: v, deps: deps, onClose: views.close),
              _ => const SizedBox.shrink(key: ValueKey('sky')),
            },
          ),
        ),
      );
}

/// Opens [text] through a real offer and a yes, as the app does.
Future<ViewHost> open(WidgetTester t, String text, BreathDeps deps,
    {double textScale = 1, bool reduceMotion = false, Size size = phone, double keyboard = 0}) async {
  phoneSurface(t, size: size);
  final views = ViewHost();
  final offer = ViewOffer(host: views, post: (_, _) {}, timer: (d, f) => _NoTimer(), log: (_) {});
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(
      size: size,
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: _Host(views, deps),
  ));
  expect(offer.claim(text), isTrue, reason: text);
  await t.pump();
  expect(find.byType(BreathView), findsNothing, reason: 'no view before a yes');
  expect(offer.claim('yes'), isTrue);
  await t.pump();
  await t.pump();
  expect(find.byType(BreathView), findsOneWidget);
  return views;
}

class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

Future<void> tapKey(WidgetTester t, Key k) async {
  await t.ensureVisible(find.byKey(k));
  await t.pump();
  await t.tap(find.byKey(k));
  await t.pump();
  await t.pump();
}

void main() {
  setUpAll(loadCaptionFonts);
  setUp(() => registerBreathNames(lib.names));
  tearDown(() => registerBreathNames(const []));

  late InMemoryStateStore store;
  setUp(() => store = InMemoryStateStore());
  BreathDeps deps([BreathLibrary? l]) => BreathDeps(library: Future.value(l ?? lib), store: store);
  Future<void> profile({bool advanced = false}) =>
      store.setString(breathProfileKey, BreathProfile(advanced: advanced, cleared: const {ScreenKind.standard}).encode());

  for (final scale in [1.0, 1.5, 2.0]) {
    group('at ${scale}x text', () {
      testWidgets('first-run onboarding: every question fits', (t) async {
        await open(t, 'do box breathing', deps(), textScale: scale);
        expect(find.text(introText), findsOneWidget);
        expectFits(t, reason: 'intro');
        await tapKey(t, BreathView.yesKey);
        expect(find.text(howText), findsOneWidget);
        expectFits(t, reason: 'how');
        await tapKey(t, BreathView.yesKey);
        expect(find.text(screenQuestion), findsOneWidget);
        for (final item in screenItems[ScreenKind.standard]!) {
          expect(find.text(item), findsOneWidget, reason: item);
        }
        expectFits(t, reason: 'screen');
        await tapKey(t, BreathView.noKey);
        expect(find.text(advancedQuestion), findsOneWidget);
        expectFits(t, reason: 'advanced');
        await tapKey(t, BreathView.noKey);
        expect(find.text('Start Box, fixed count now?'), findsOneWidget);
        expectFits(t, reason: 'start');
      });

      testWidgets('the full library list for an advanced practitioner fits', (t) async {
        await profile(advanced: true);
        await open(t, 'start breathwork', deps(), textScale: scale);
        expectFits(t, reason: 'choose');
        await tapKey(t, BreathView.listKey);
        final all = lib.listFor(advanced: true);
        expect(all.length, lib.all.length); // every technique, basics first
        for (final tq in all) {
          await t.ensureVisible(find.byKey(ValueKey('breath-item-${tq.id}')));
          await t.pump();
          expectFits(t, reason: tq.id);
        }
        // Advanced entries carry a quiet "advanced" tag in note type.
        final holotropic = find.byKey(const ValueKey('breath-item-holotropic'));
        expect(find.descendant(of: holotropic, matching: find.text('Holotropic breathwork')), findsOneWidget);
        final tag = find.descendant(of: holotropic, matching: find.text('advanced'));
        expect(tag, findsOneWidget);
        expect(t.widget<Text>(tag).style!.fontSize, TypeScale.note(Palette.night.ink2).fontSize);
        expect(TypeScale.isInverse(t.widget<Text>(tag).style), isTrue);
      });

      testWidgets('a session, paused, then stopped, fits', (t) async {
        await profile();
        await open(t, 'do box breathing', deps(), textScale: scale);
        await tapKey(t, BreathView.yesKey);
        await t.pump(const Duration(milliseconds: 100));
        expect(find.byKey(BreathView.visualKey), findsOneWidget);
        expectFits(t, reason: 'count-in');
        await t.pump(const Duration(seconds: 50));
        expect(find.textContaining('left'), findsOneWidget);
        expectFits(t, reason: 'running');
        await tapKey(t, BreathView.pauseKey);
        expect(find.textContaining('Paused.'), findsOneWidget);
        expectFits(t, reason: 'paused');
        await tapKey(t, BreathView.stopKey);
        expect(find.text(lib.byId('box_breathing')!.copy.end), findsOneWidget);
        expectFits(t, reason: 'ended');
      });
    });
  }

  testWidgets('reduced motion: the countdown fits at 360 px', (t) async {
    await profile();
    await open(t, 'do paced breath', deps(), reduceMotion: true);
    await tapKey(t, BreathView.yesKey);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(BreathView.countdownKey), findsOneWidget);
    expectFits(t);
    await tapKey(t, BreathView.stopKey);
  });

  testWidgets('session clock: the timer starts after the count-in and counts down', (t) async {
    // Box breathing: 4 phases of 4 s = 16 s a cycle, 3 count-in cycles = 48 s.
    final box = lib.byId('box_breathing')!;
    await profile();
    await open(t, 'do box breathing', deps());
    await tapKey(t, BreathView.yesKey);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Getting ready: breath 1 of 3'), findsOneWidget);
    await t.pump(const Duration(seconds: 17)); // 17.1 s: second cycle
    expect(find.text('Getting ready: breath 2 of 3'), findsOneWidget);
    await t.pump(const Duration(seconds: 41)); // 58.1 s: 10.1 s into the session
    final left = box.durationS - 10; // ceil(duration - 10.1) = duration - 10
    expect(find.text('${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')} left'), findsOneWidget);
    await tapKey(t, BreathView.stopKey);
  });

  testWidgets('notices fit: holotropic is explained, an advanced technique is refused', (t) async {
    await profile();
    final views = await open(t, 'do holotropic breathing', deps());
    expect(find.text(lib.byId('holotropic')!.copy.notice), findsOneWidget);
    expect(find.byKey(BreathView.yesKey), findsNothing);
    expectFits(t, reason: 'holotropic');
    await tapKey(t, BreathView.closeKey);
    expect(views.current, isNull);

    final advanced = lib.all.firstWhere((x) => !x.isBasic && !x.screens.contains(ScreenKind.holotropic));
    registerBreathNames(lib.names);
    await open(t, 'do ${normaliseBreathName(advanced.name)}', deps());
    expect(find.textContaining('is an advanced technique'), findsOneWidget);
    expectFits(t, reason: 'advanced only');
  });

  testWidgets('a typed name that matches nothing says so and fits', (t) async {
    await profile();
    await open(t, 'start breathwork', deps());
    await t.enterText(find.byKey(BreathView.nameKey), 'square-ish breathing');
    await tapKey(t, BreathView.chooseKey);
    expect(find.text('No technique by that name. Check the spelling or see the list.'), findsOneWidget);
    expectFits(t);
  });

  testWidgets('empty library: the list says nothing is installed, not a blank heading', (t) async {
    await profile();
    await open(t, 'start breathwork', deps(BreathLibrary(const [])));
    await tapKey(t, BreathView.listKey);
    expect(find.text('The basic techniques, in order:'), findsNothing);
    expect(find.text(BreathView.emptyLibraryText), findsOneWidget);
    expectFits(t);
  });

  testWidgets('a failed library load is readable and Close returns to the sky', (t) async {
    final views = await open(t, 'start breathwork',
        BreathDeps(library: Future.error(StateError('synthetic')), store: store));
    expect(find.text('The breathwork library could not load.'), findsOneWidget);
    expectFits(t);
    await tapKey(t, BreathView.closeKey);
    expect(views.current, isNull);
    expect(find.byType(BreathView), findsNothing);
    expect(find.byKey(const ValueKey('sky')), findsOneWidget);
  });

  testWidgets('Close mid-session stops it and returns to the sky', (t) async {
    await profile();
    final views = await open(t, 'do box breathing', deps());
    await tapKey(t, BreathView.yesKey);
    await t.pump(const Duration(seconds: 1));
    await tapKey(t, BreathView.stopKey);
    await tapKey(t, BreathView.closeKey);
    expect(views.current, isNull);
    expect(find.byKey(const ValueKey('sky')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a short phone (360 x 560) at 1.5x text: Stop and Pause stay on screen', (t) async {
    await profile();
    await open(t, 'do box breathing', deps(), textScale: 1.5, size: const Size(360, 560));
    await tapKey(t, BreathView.yesKey);
    await t.pump(const Duration(seconds: 50));
    expectFits(t);
    for (final k in [BreathView.stopKey, BreathView.pauseKey]) {
      final r = t.getRect(find.byKey(k));
      expect(r.bottom, lessThanOrEqualTo(560), reason: '$k');
      expect(r.height, greaterThanOrEqualTo(48), reason: '$k');
    }
    await tapKey(t, BreathView.stopKey);
  });

  group('UI-4: one glass sheet for the steps, the session on open sky', () {
    testWidgets('steps sit on one glass sheet with Close at the top right', (t) async {
      await open(t, 'do box breathing', deps());
      expect(find.byType(GlassSheet), findsOneWidget);
      expect(find.byType(GlassPanel), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      final close = t.getRect(find.byKey(BreathView.closeKey));
      expect(close.top, lessThan(120));
      expect(close.right, greaterThan(300));
      expect(close.height, greaterThanOrEqualTo(48));
      // Yes / No are one action row with no glass of their own.
      expect(find.ancestor(of: find.byKey(BreathView.yesKey), matching: find.byType(GlassActions)), findsOneWidget);
      expect(find.descendant(of: find.byType(GlassActions), matching: find.byType(GlassPanel)), findsNothing);
    });

    testWidgets('step text is start-aligned: body, question, choice, notice', (t) async {
      TextAlign? align(String text) => t.widget<Text>(find.text(text)).textAlign;
      await open(t, 'do box breathing', deps());
      expect(align(introText), TextAlign.start);
      expect(align('Continue?'), TextAlign.start);
      // The question in the reply face, the body in Jost.
      expect(t.widget<Text>(find.text('Continue?')).style!.fontFamily, Fonts.serif);
      expect(t.widget<Text>(find.text(introText)).style!.fontFamily, Fonts.sans);
      await tapKey(t, BreathView.yesKey);
      await tapKey(t, BreathView.yesKey);
      await tapKey(t, BreathView.yesKey); // screen: yes
      expect(align('This session will not start.'), TextAlign.start);
      expect(align(defaultNotice), TextAlign.start);
    });

    testWidgets('the typed choice: a field with no "For example" hint, Choose and the list as actions', (t) async {
      await profile();
      await open(t, 'start breathwork', deps());
      expect(find.textContaining('For example'), findsNothing);
      expect(find.byKey(BreathView.nameKey), findsOneWidget);
      for (final k in [BreathView.chooseKey, BreathView.listKey]) {
        expect(t.getSize(find.byKey(k)).height, greaterThanOrEqualTo(48));
      }
      await tapKey(t, BreathView.listKey);
      for (final b in lib.basics()) {
        final row = find.byKey(ValueKey('breath-item-${b.id}'));
        expect(t.getSize(row).height, greaterThanOrEqualTo(48), reason: b.id);
        expect(t.widget<Text>(find.descendant(of: row, matching: find.text(b.name))).textAlign, TextAlign.start);
      }
    });

    testWidgets('during a session: at most one glass, no TextButton, a ring of light', (t) async {
      await profile();
      await open(t, 'do box breathing', deps());
      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(milliseconds: 100));
      for (final at in [Duration.zero, const Duration(seconds: 50)]) {
        await t.pump(at);
        expect(find.byType(GlassPanel).evaluate().length, lessThanOrEqualTo(1), reason: '$at');
        expect(find.byType(GlassSheet), findsNothing, reason: '$at');
        expect(find.byType(TextButton), findsNothing, reason: '$at');
        expect(find.byKey(BreathView.visualKey), findsOneWidget, reason: '$at');
      }
      // Pause and Stop are one action row at the bottom.
      final row = find.byType(GlassActions);
      expect(find.descendant(of: row, matching: find.byKey(BreathView.pauseKey)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byKey(BreathView.stopKey)), findsOneWidget);
      expect(t.getRect(row).bottom, greaterThan(700));
      await tapKey(t, BreathView.stopKey);
    });

    testWidgets('by day the steps take the day inks', (t) async {
      phoneSurface(t);
      await t.pumpWidget(MaterialApp(
        home: SkyLight(
          daylight: 1,
          palette: Palette.day,
          child: BreathView(request: const BreathRequest('box breathing'), deps: deps(), onClose: () {}),
        ),
      ));
      await t.pump();
      await t.pump();
      for (final s in ['Continue?', introText]) {
        final style = t.renderObject<RenderParagraph>(find.text(s)).text.style!;
        expect(TypeScale.isInverse(style), isTrue, reason: s);
        expect(style.shadows!.first.color.withValues(alpha: 1), Palette.day.halo.withValues(alpha: 1), reason: s);
      }
    });

    testWidgets('the pacer is a ring: the centre stays transparent', (t) async {
      final recorder = ui.PictureRecorder();
      BreathPainter(level: 0.5, color: Palette.night.ink).paint(Canvas(recorder), const Size(200, 200));
      final image = (await t.runAsync(() => recorder.endRecording().toImage(200, 200)))!;
      final bytes = (await t.runAsync(() => image.toByteData()))!;
      int alphaAt(int x, int y) => bytes.getUint8((y * 200 + x) * 4 + 3);
      expect(alphaAt(100, 100), 0);
      // Somewhere along the middle row the ring is lit.
      expect([for (var x = 0; x < 200; x++) alphaAt(x, 100)].any((a) => a > 0), isTrue);
    });
  });

  group('the ring on the centre of the open sky', () {
    /// Starts box breathing (profile stored) and runs into the session.
    Future<void> session(WidgetTester t, {Size size = phone, double scale = 1, double keyboard = 0}) async {
      await profile();
      await open(t, 'do box breathing', deps(), size: size, textScale: scale, keyboard: keyboard);
      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(seconds: 50));
    }

    void expectCentred(WidgetTester t, {required Size size, double keyboard = 0, String? reason}) {
      final sky = t.getRect(find.byKey(BreathView.skyKey));
      final ring = t.getRect(find.byKey(BreathView.visualKey));
      final close = t.getRect(find.byKey(BreathView.closeKey));
      final stop = t.getRect(find.byKey(BreathView.stopKey));
      expect(ring.width, ring.height, reason: '$reason square');
      expect(ring.width, greaterThanOrEqualTo(BreathView.ringMin), reason: '$reason size');
      expect((ring.center.dx - size.width / 2).abs(), lessThan(0.5), reason: '$reason horizontal');
      expect((ring.center.dy - sky.center.dy).abs(), lessThan(0.5), reason: '$reason vertical');
      expect(sky.top, greaterThanOrEqualTo(close.bottom), reason: '$reason under Close');
      expect(ring.overlaps(close), isFalse, reason: '$reason never on Close');
      expect(ring.top, greaterThanOrEqualTo(sky.top), reason: reason);
      expect(ring.bottom, lessThanOrEqualTo(sky.bottom), reason: reason);
      expect(stop.bottom, lessThanOrEqualTo(size.height - keyboard), reason: '$reason Stop above the keyboard');
      // The phase sits above the ring, the cue below it, neither on it.
      const phases = {'Breathe in', 'A little more in', 'Pause, if comfortable', 'Breathe out'};
      final phase = t.getRect(find.byWidgetPredicate((w) => w is Text && phases.contains(w.data)));
      expect(phase.bottom, lessThanOrEqualTo(ring.top), reason: '$reason phase above');
      final cue = find.byType(GlassPanel);
      if (cue.evaluate().isNotEmpty) {
        expect(t.getRect(cue).top, greaterThanOrEqualTo(ring.bottom), reason: '$reason cue below');
      }
    }

    testWidgets('at 360 x 780 the ring is centred, 320 px at most, under Close', (t) async {
      await session(t);
      expectCentred(t, size: phone);
      expect(t.getSize(find.byKey(BreathView.visualKey)).width, lessThanOrEqualTo(BreathView.ringMax));
      expectFits(t);
      await tapKey(t, BreathView.stopKey);
    });

    testWidgets('with the keyboard open the ring shrinks, stays centred, and Stop stays above it', (t) async {
      await session(t, keyboard: 300);
      expectCentred(t, size: phone, keyboard: 300);
      expectFits(t);
      await tapKey(t, BreathView.stopKey);
    });

    for (final (size, scale) in [(const Size(360, 560), 1.5), (phone, 2.0), (const Size(800, 1280), 1.0)]) {
      testWidgets('at ${size.width.toInt()} x ${size.height.toInt()} and ${scale}x text the ring is centred', (t) async {
        await session(t, size: size, scale: scale);
        expectCentred(t, size: size, reason: '$size $scale');
        expectFits(t, width: size.width);
        await tapKey(t, BreathView.stopKey);
      });
    }

    testWidgets('the ring keeps its size and place through the phases and the cues', (t) async {
      await session(t);
      final first = t.getRect(find.byKey(BreathView.visualKey));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(seconds: 2));
        expect(t.getRect(find.byKey(BreathView.visualKey)), first, reason: 'step $i');
      }
      await tapKey(t, BreathView.stopKey);
    });

    testWidgets('reduced motion: the countdown sits on the same centre', (t) async {
      await profile();
      await open(t, 'do box breathing', deps(), reduceMotion: true);
      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(seconds: 50));
      final sky = t.getRect(find.byKey(BreathView.skyKey));
      final count = t.getRect(find.byKey(BreathView.countdownKey));
      expect((count.center.dx - 180).abs(), lessThan(0.5));
      expect((count.center.dy - sky.center.dy).abs(), lessThan(1));
      expectFits(t);
      await tapKey(t, BreathView.stopKey);
    });
  });

  group('Close keeps one place', () {
    testWidgets('steps, the session and the end share one Close rect', (t) async {
      await profile();
      await open(t, 'do box breathing', deps());
      final step = t.getRect(find.byKey(BreathView.closeKey));
      expect(step.height, greaterThanOrEqualTo(48));
      expect(step.right, closeTo(360 - Space.s8, 0.5));
      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(seconds: 2));
      expect(t.getRect(find.byKey(BreathView.closeKey)), step, reason: 'session');
      await tapKey(t, BreathView.stopKey);
      expect(t.getRect(find.byKey(BreathView.closeKey)), step, reason: 'end');
    });

    testWidgets('Close during a session stops it and returns to the sky', (t) async {
      await profile();
      final views = await open(t, 'do box breathing', deps());
      await tapKey(t, BreathView.yesKey);
      await t.pump(const Duration(seconds: 3));
      await tapKey(t, BreathView.closeKey);
      expect(views.current, isNull);
      expect(find.byKey(const ValueKey('sky')), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(t.takeException(), isNull);
    });
  });

  group('calm onboarding: one question a screen, large centred answers', () {
    testWidgets('Yes and No are large and centred on every question', (t) async {
      await open(t, 'do box breathing', deps());
      for (var i = 0; i < 4; i++) {
        final yes = t.getRect(find.byKey(BreathView.yesKey));
        final no = t.getRect(find.byKey(BreathView.noKey));
        expect(yes.height, greaterThanOrEqualTo(BreathView.answerHeight), reason: 'step $i');
        expect(no.height, greaterThanOrEqualTo(BreathView.answerHeight), reason: 'step $i');
        expect(((yes.left + no.right) / 2 - 180).abs(), lessThan(0.5), reason: 'step $i centred');
        expect(find.byKey(BreathView.answerKey), findsOneWidget, reason: 'step $i');
        // One question: one reply-face line on the screen besides the title.
        final serif = t.widgetList<Text>(find.byType(Text)).where(
            (w) => w.style?.fontFamily == Fonts.serif && w.style?.fontSize == TypeScale.reply(Palette.night.ink).fontSize);
        expect(serif.length, 1, reason: 'step $i');
        expectFits(t, reason: 'step $i');
        await tapKey(t, i == 2 ? BreathView.noKey : BreathView.yesKey);
      }
    });

    testWidgets('the onboarding completes with typed answers alone', (t) async {
      await open(t, 'do box breathing', deps());
      Future<void> type(String text) async {
        await t.enterText(find.byKey(BreathView.answerKey), text);
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump();
        await t.pump();
      }

      await type('yes'); // intro
      expect(find.text(howText), findsOneWidget);
      await type('yes'); // how
      expect(find.text(screenQuestion), findsOneWidget);
      await type('not sure');
      expect(find.text(BreathView.missText), findsOneWidget);
      expect(find.text(screenQuestion), findsOneWidget);
      expectFits(t);
      await type('no'); // screen
      expect(find.text(advancedQuestion), findsOneWidget);
      expect(find.text(BreathView.missText), findsNothing);
      await type('no'); // advanced
      expect(find.text('Start Box, fixed count now?'), findsOneWidget);
      final saved = BreathProfile.decode(await store.getString(breathProfileKey))!;
      expect(saved.advanced, isFalse);
      expect(saved.cleared, {ScreenKind.standard});
      await type('yes'); // start
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(BreathView.visualKey), findsOneWidget);
      await tapKey(t, BreathView.stopKey);
    });

    testWidgets('with the keyboard open the answers and the field stay above it', (t) async {
      await open(t, 'do box breathing', deps(), size: const Size(360, 640), keyboard: 280);
      for (final k in [BreathView.yesKey, BreathView.noKey, BreathView.answerKey]) {
        await t.ensureVisible(find.byKey(k));
        await t.pump();
        expect(t.getRect(find.byKey(k)).bottom, lessThanOrEqualTo(640 - 280), reason: '$k');
      }
      expectFits(t);
    });
  });
}
