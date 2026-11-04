// The council trace panel under a council answer (T18) at phone width: it
// shows one line per expert and the web search line, open by default, folds
// and opens with a tap, fits 360 px, and its measured height is the drawn
// height open and folded. Synthetic text only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/council_flow.dart';
import 'package:illunis_client/widgets/chat_composer.dart';
import 'package:illunis_client/widgets/glass/glass_exchange.dart';
import 'package:illunis_client/widgets/glass/glass_surface.dart';

import '../app/view_audit_helpers.dart';

const lines = [
  'Sleep and lifestyle: 3 sources, web search not needed',
  'Diet and nutrition: 1 bank and 2 web sources, web search used',
  'Web search (Tavily): ran for Diet and nutrition',
];

ChatThread councilThread() => ChatThread()
  ..addUser('Why do I keep waking up at 3am?')
  ..addAssistant('Synthetic synthesis: a steady wind-down and less late caffeine may help.')
  ..attachSources('Sources: Synthetic sleep note · Synthetic web page')
  ..attachTrace(lines);

void main() {
  setUpAll(loadCaptionFonts);

  testWidgets('the panel shows the lines open by default, and a tap folds and opens it', (t) async {
    phoneSurface(t);
    final thread = councilThread();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ChatComposer(thread: thread, onSubmit: (_) {}))));
    await t.pumpAndSettle();

    expect(find.text(councilTraceTitle), findsOneWidget);
    for (final l in lines) {
      expect(find.text(l), findsOneWidget);
    }
    expectFits(t, reason: 'open');
    final semantics = t.ensureSemantics();
    expect(t.getSemantics(find.byKey(GlassExchange.traceToggleKey)), isSemantics(isButton: true, isExpanded: true, hasExpandedState: true, hasTapAction: true));
    expect(t.getSize(find.byKey(GlassExchange.traceToggleKey)).height, greaterThanOrEqualTo(48));

    await t.tap(find.byKey(GlassExchange.traceToggleKey));
    await t.pumpAndSettle();
    expect(thread.traceOpen, isFalse);
    expect(find.text(councilTraceTitle), findsOneWidget, reason: 'the title stays to open it again');
    for (final l in lines) {
      expect(find.text(l), findsNothing);
    }
    expect(find.text('Sources: Synthetic sleep note · Synthetic web page'), findsOneWidget);
    expectFits(t, reason: 'folded');
    expect(t.getSemantics(find.byKey(GlassExchange.traceToggleKey)), isSemantics(isButton: true, isExpanded: false, hasExpandedState: true, hasTapAction: true));

    await t.tap(find.byKey(GlassExchange.traceToggleKey));
    await t.pumpAndSettle();
    expect(find.text(lines.first), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('measured height is the drawn height, open and folded, at 328 px', (t) async {
    phoneSurface(t);
    final entries = councilThread().latestExchange;
    for (final open in [true, false]) {
      await t.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 328,
            height: 700,
            child: GlassExchange(entries: entries, onChoice: (_) {}, grow: Duration.zero, traceOpen: open),
          ),
        ),
      ));
      await t.pump();
      final fit = fitExchange(ExchangeContent.of(entries),
          maxWidth: 328, height: 700, scaler: TextScaler.noScaling, traceOpen: open);
      final glass = t.getRect(find.byType(GlassPanel));
      expect(glass.height, closeTo(fit.height, 1), reason: 'open: $open');
      expect(glass.width, closeTo(fit.width, 0.5), reason: 'open: $open');
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('no trace, no panel', (t) async {
    phoneSurface(t);
    final thread = ChatThread()
      ..addUser('Synthetic question?')
      ..addAssistant('Synthetic answer.');
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ChatComposer(thread: thread, onSubmit: (_) {}))));
    await t.pumpAndSettle();
    expect(find.text(councilTraceTitle), findsNothing);
  });
}
