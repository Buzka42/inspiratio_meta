import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/assistant_inbox.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';

import 'w5_fakes.dart';

// Synthetic items only.
InboxItem item(String id, int ts, {String kind = 'message', String? text}) =>
    InboxItem(id: id, kind: kind, text: text ?? 'text $id', ts: ts);

void main() {
  late FakeServerPort server;
  late InMemoryStateStore store;
  late Speaker sp;
  late FakeTimers timers;
  late bool quiet, enabled;
  late DateTime now;
  late AssistantInbox inbox;

  AssistantInbox make() => AssistantInbox(
        server: server,
        store: store,
        speak: sp.speak,
        quiet: () => quiet,
        enabled: () => enabled,
        timer: timers.call,
        clock: () => now,
        log: (_) {},
      );

  setUp(() {
    server = FakeServerPort();
    store = InMemoryStateStore();
    sp = Speaker();
    timers = FakeTimers();
    quiet = true;
    enabled = true;
    now = DateTime(2026, 10, 25, 9);
    inbox = make();
  });

  group('mergeInbox', () {
    test('orders by ts, keeps arrival order on a tie, drops repeats', () {
      final out = mergeInbox([item('b', 20), item('a', 10)], [item('c', 15), item('a', 10), item('d', 20)]);
      expect(out.map((i) => i.id), ['a', 'c', 'b', 'd']);
    });

    test('keeps the newest $inboxKeep', () {
      final out = mergeInbox(const [], [for (var i = 0; i < inboxKeep + 5; i++) item('i$i', i)]);
      expect(out, hasLength(inboxKeep));
      expect(out.first.id, 'i5');
    });
  });

  test('poll does nothing while memory mode is not the assistant', () async {
    enabled = false;
    server.inboxBatches.add(InboxBatch(items: [item('a', 1)]));
    await inbox.poll();
    expect(server.inboxPolls, 0);
    expect(inbox.pending, isEmpty);
  });

  test('poll reads every page while more, then speaks oldest first at the pause', () async {
    server.inboxBatches
      ..add(InboxBatch(items: [item('b', 20)], more: true))
      ..add(InboxBatch(items: [item('a', 10, kind: 'reminder')]));
    await inbox.poll();
    expect(server.inboxPolls, 2);
    expect(inbox.pending.map((i) => i.id), ['a', 'b']);
    expect(sp.spoken, isEmpty, reason: 'nothing until the pause timer');
    expect(timers.active.single.after, const Duration(seconds: 2));
    timers.fireActive();
    await settle();
    expect(sp.spoken, ['A reminder from your assistant: text a', 'A message from your assistant: text b']);
    expect(inbox.pending, isEmpty);
  });

  test('polls are throttled unless forced', () async {
    await inbox.poll();
    await inbox.poll();
    expect(server.inboxPolls, 1);
    now = now.add(const Duration(seconds: 31));
    await inbox.poll();
    await inbox.poll(force: true);
    expect(server.inboxPolls, 3);
  });

  test('never speaks over the user or a reply: waits, re-arming, until quiet', () async {
    quiet = false;
    server.inboxBatches.add(InboxBatch(items: [item('a', 1)]));
    await inbox.poll();
    for (var i = 0; i < 3; i++) {
      timers.fireActive();
      await settle();
      expect(sp.spoken, isEmpty);
      expect(timers.active, hasLength(1), reason: 're-armed while waiting');
    }
    quiet = true;
    timers.fireActive();
    await settle();
    expect(sp.spoken, ['A message from your assistant: text a']);
    expect(timers.active, isEmpty);
  });

  test('an interrupted item stays first and is spoken at the next pause', () async {
    server.inboxBatches.add(InboxBatch(items: [item('a', 1), item('b', 2)]));
    await inbox.poll();
    sp.results.add(false);
    timers.fireActive();
    await settle();
    expect(inbox.pending.map((i) => i.id), ['a', 'b']);
    timers.fireActive();
    await settle();
    expect(sp.spoken.skip(1), ['A message from your assistant: text a', 'A message from your assistant: text b']);
  });

  test('items survive a restart until spoken', () async {
    server.inboxBatches.add(InboxBatch(items: [item('a', 1), item('b', 2)]));
    quiet = false;
    await inbox.poll();
    final again = make();
    await again.load();
    expect(again.pending.map((i) => i.id), ['a', 'b']);
    expect(await store.getString(StoreKeys.assistantInbox), isNot(contains('token')));
  });

  test('morning digest folds waiting items in, then nothing is left for the pause', () async {
    quiet = false;
    server.inboxBatches.add(InboxBatch(items: [item('a', 1), item('b', 2, kind: 'bot_reply')]));
    await inbox.poll();
    expect(await inbox.speakForDigest(), isTrue);
    expect(sp.spoken, [
      'Also: A message from your assistant: text a',
      'Also: A reply came in through your assistant: text b',
    ]);
    quiet = true;
    timers.fireActive();
    await settle();
    expect(sp.spoken, hasLength(2));
  });

  test('a digest fold the user interrupts returns false and keeps the rest', () async {
    server.inboxBatches.add(InboxBatch(items: [item('a', 1), item('b', 2)]));
    quiet = false;
    await inbox.poll();
    sp.results.addAll([true, false]);
    expect(await inbox.speakForDigest(), isFalse);
    expect(inbox.pending.map((i) => i.id), ['b']);
  });

  test('a failed poll keeps what is waiting and logs a code', () async {
    final logs = <String>[];
    server.inboxBatches.add(InboxBatch(items: [item('a', 1)]));
    quiet = false;
    final i = AssistantInbox(
        server: server,
        store: store,
        speak: sp.speak,
        quiet: () => quiet,
        enabled: () => true,
        timer: timers.call,
        clock: () => now,
        log: logs.add);
    await i.poll();
    server.inboxError = const ServerException(503, 'inbox_unavailable');
    await i.poll(force: true);
    expect(i.pending.single.id, 'a');
    expect(logs.last, 'inbox: poll_failed code=inbox_unavailable');
  });
}
