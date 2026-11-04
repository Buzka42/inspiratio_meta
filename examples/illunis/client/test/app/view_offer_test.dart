// Ask before opening any view (PLAN.md rule 2026-10-28). Synthetic text.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/view_offer.dart';
import 'package:illunis_client/app/view_requests.dart';

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

({ViewOffer offer, ViewHost host, List<String> posts, List<(String, bool?)> results, List<FakeTimer> timers})
    rig() {
  final host = ViewHost();
  final posts = <String>[];
  final results = <(String, bool?)>[];
  final timers = <FakeTimer>[];
  final offer = ViewOffer(
    host: host,
    post: (p, id) => posts.add('$id $p'),
    resolved: (id, a) => results.add((id, a)),
    timer: (d, f) {
      expect(d, ViewOffer.timeout);
      final t = FakeTimer(f);
      timers.add(t);
      return t;
    },
    log: (_) {},
  );
  return (offer: offer, host: host, posts: posts, results: results, timers: timers);
}

void main() {
  group('parseViewRequest', () {
    test('matches explicit view phrases', () {
      expect(parseViewRequest('Show my logs'), const ViewRequest(ViewKind.logs, 'your logs'));
      expect(parseViewRequest('please open the strength log'),
          const ViewRequest(ViewKind.strength, 'your strength log'));
      expect(parseViewRequest('Can you show me my running log?'),
          const ViewRequest(ViewKind.run, 'your run log'));
      expect(parseViewRequest('log my run'), const ViewRequest(ViewKind.run, 'your run log'));
      expect(parseViewRequest('add a meal'), const ViewRequest(ViewKind.food, 'your food log'));
      expect(parseViewRequest('show my sleep data'), const ViewRequest(ViewKind.wellbeing, 'your wellbeing view'));
      expect(parseViewRequest('start breathwork'), const ViewRequest(ViewKind.breathwork, 'breathwork'));
      expect(parseViewRequest('I want to do some breathing exercises'),
          const ViewRequest(ViewKind.breathwork, 'breathwork'));
    });

    test('questions and other text are not requests', () {
      for (final t in ['what is breathwork', 'how do I log my food', 'show me the sky', 'logs', 'yes']) {
        expect(parseViewRequest(t), isNull, reason: t);
      }
    });
  });

  test('a request only offers; nothing opens without a yes', () {
    final r = rig();
    expect(r.offer.claim('show my logs'), isTrue);
    expect(r.posts, ['view-1 Open your logs?']);
    expect(r.host.current, isNull);
    expect(r.offer.offerOpen, isTrue);
  });

  test('yes opens the view through ViewHost', () {
    final r = rig();
    r.offer.claim('open the strength log');
    expect(r.offer.claim('Yes'), isTrue);
    expect(r.host.current, const ViewRequest(ViewKind.strength, 'your strength log'));
    expect(r.results, [('view-1', true)]);
    expect(r.offer.offerOpen, isFalse);
    // The yes is spent: another yes is not an answer to anything.
    expect(r.offer.claim('yes'), isFalse);
    r.host.close();
    expect(r.host.current, isNull);
  });

  test('no declines; nothing opens', () {
    final r = rig();
    r.offer.claim('start breathwork');
    expect(r.offer.claim('no thanks'), isTrue);
    expect(r.host.current, isNull);
    expect(r.results, [('view-1', false)]);
  });

  test('the timeout without an answer cancels; a late yes opens nothing', () {
    final r = rig();
    r.offer.claim('show my logs');
    r.timers.single.fire();
    expect(r.offer.offerOpen, isFalse);
    expect(r.results, [('view-1', null)]);
    expect(r.offer.claim('yes'), isFalse);
    expect(r.host.current, isNull);
  });

  test('a new turn cancels the offer and is left for normal handling', () {
    final r = rig();
    r.offer.claim('show my logs');
    expect(r.offer.claim('how did I sleep'), isFalse);
    expect(r.results, [('view-1', null)]);
    expect(r.host.current, isNull);
    expect(r.offer.claim('yes'), isFalse);
  });

  test('one offer at a time: a second request replaces the first', () {
    final r = rig();
    r.offer.claim('show my logs');
    expect(r.offer.claim('start breathwork'), isTrue);
    expect(r.results, [('view-1', null)]);
    expect(r.timers.first.cancelled, isTrue);
    expect(r.posts.last, 'view-2 Open breathwork?');
    expect(r.offer.openOfferId, 'view-2');
    r.timers.first.fire(); // the old timer does nothing
    expect(r.offer.offerOpen, isTrue);
    r.offer.claim('yes');
    expect(r.host.current?.kind, ViewKind.breathwork);
  });

  test('an offer waits 90 s for its answer', () {
    expect(ViewOffer.timeout, const Duration(seconds: 90));
  });

  // The real timer, on the test's fake clock.
  testWidgets('a yes typed after 40 s still opens the view', (t) async {
    final host = ViewHost();
    final results = <bool?>[];
    final offer = ViewOffer(host: host, post: (_, _) {}, resolved: (_, a) => results.add(a), log: (_) {});
    offer.claim('do some breathing exercises');
    await t.pump(const Duration(seconds: 40));
    expect(offer.offerOpen, isTrue);
    expect(offer.claim('yes'), isTrue);
    expect(host.current?.kind, ViewKind.breathwork);
    expect(results, [true]);
  });

  testWidgets('the offer is still open at 89 s and closed at 90 s', (t) async {
    final host = ViewHost();
    final results = <bool?>[];
    final offer = ViewOffer(host: host, post: (_, _) {}, resolved: (_, a) => results.add(a), log: (_) {});
    offer.claim('show my logs');
    await t.pump(const Duration(seconds: 89));
    expect(offer.offerOpen, isTrue);
    await t.pump(const Duration(seconds: 1));
    expect(offer.offerOpen, isFalse);
    expect(results, [null]);
    expect(offer.claim('yes'), isFalse);
    expect(host.current, isNull);
  });

  test('cancel() closes an open offer', () {
    final r = rig();
    r.offer.claim('show my logs');
    r.offer.cancel();
    expect(r.results, [('view-1', null)]);
    expect(r.offer.claim('yes'), isFalse);
  });
}
