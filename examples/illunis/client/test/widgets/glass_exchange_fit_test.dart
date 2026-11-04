// The reply's fit ladder (UI_PLAN UI-2) with the real fonts: what an
// exchange shows, the order of the rungs (size, then your line, then the
// inset), that the measurement matches the layout, and that the size never
// climbs back within one exchange. Synthetic text only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/council_flow.dart' show notMedicalAdviceLine;
import 'package:illunis_client/ui/tokens.dart';
import 'package:illunis_client/widgets/glass/glass_exchange.dart';
import 'package:illunis_client/widgets/glass/glass_surface.dart';

import '../app/view_audit_helpers.dart';

String words(int n) => List.generate(n, (i) => ['quiet', 'water', 'walk', 'rest', 'light', 'evening'][i % 6]).join(' ');

void main() {
  setUpAll(loadCaptionFonts);
  const scaler = TextScaler.noScaling;

  test('content: your line, paragraphs, sources and the disclaimer split out, the open offer', () {
    final c = ExchangeContent.of([
      const ChatEntry(role: ChatRole.user, text: 'Synthetic question?'),
      const ChatEntry(role: ChatRole.assistant, text: 'Synthetic answer. $notMedicalAdviceLine', sources: 'Sources: A · B'),
      const ChatEntry(role: ChatRole.assistant, text: 'Open your logs?', offer: ChatOffer('v1')),
    ]);
    expect(c.echo, 'Synthetic question?');
    expect(c.paragraphs, ['Synthetic answer.', 'Open your logs?']);
    expect(c.notes, ['Sources: A · B', notMedicalAdviceLine]);
    expect(c.offerId, 'v1');
    final closed = ExchangeContent.of(const [
      ChatEntry(role: ChatRole.assistant, text: 'Open your logs?', offer: ChatOffer('v1', OfferState.declined)),
    ]);
    expect(closed.offerId, isNull);
  });

  test('the ladder: 22, 20, 18, then your line goes, then the inset tightens', () {
    final c = ExchangeContent(echo: 'Synthetic question about sleep?', paragraphs: [words(90)], notes: const ['Sources: A']);
    final tall = fitExchange(c, maxWidth: 328, height: 2000, scaler: scaler);
    expect(tall.size, 22);
    expect(tall.echo, isTrue);
    double h(double size, {bool echo = true, EdgeInsets inset = ExchangeMetrics.inset}) =>
        measureExchange(c, size: size, echo: echo, inset: inset, maxWidth: 328, scaler: scaler).height;
    expect(fitExchange(c, maxWidth: 328, height: h(20), scaler: scaler).size, 20);
    final at18 = fitExchange(c, maxWidth: 328, height: h(18), scaler: scaler);
    expect((at18.size, at18.echo), (18, true));
    final noEcho = fitExchange(c, maxWidth: 328, height: h(18, echo: false), scaler: scaler);
    expect((noEcho.size, noEcho.echo, noEcho.inset), (18, false, ExchangeMetrics.inset));
    final tight = fitExchange(c, maxWidth: 328, height: h(18, echo: false, inset: ExchangeMetrics.tightInset), scaler: scaler);
    expect((tight.size, tight.echo, tight.inset), (18, false, ExchangeMetrics.tightInset));
    // Within an exchange the size never goes back up.
    expect(fitExchange(c, maxWidth: 328, height: 2000, scaler: scaler, cap: 18).size, 18);
  });

  testWidgets('the measured height is the drawn height, and a short reply hugs its text', (t) async {
    phoneSurface(t);
    final widths = <double>[];
    for (final text in ['Synthetic reply.', words(40)]) {
      final entries = [
        const ChatEntry(role: ChatRole.user, text: 'Synthetic question?'),
        ChatEntry(role: ChatRole.assistant, text: text, sources: 'Sources: Synthetic Passage A'),
      ];
      await t.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 328,
            height: 600,
            child: GlassExchange(entries: entries, onChoice: (_) {}, grow: Duration.zero),
          ),
        ),
      ));
      await t.pump();
      final fit = fitExchange(ExchangeContent.of(entries), maxWidth: 328, height: 600, scaler: scaler);
      final glass = t.getRect(find.byType(GlassPanel));
      expect(glass.height, closeTo(fit.height, 1), reason: text);
      expect(glass.width, closeTo(fit.width, 0.5), reason: text);
      expect(t.takeException(), isNull);
      widths.add(glass.width);
    }
    // The short one is narrower than the sky allows; the long one fills it.
    expect(widths.first, lessThan(328));
    expect(widths.last, 328);
  });

  test('Yes / No keep a 48 px row', () {
    expect(offerHeight(scaler), greaterThanOrEqualTo(Space.target));
  });
}
