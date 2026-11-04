// Settings through chat, WP2 wiring: the version notice and the bot's
// spec_request hand-off. Synthetic text.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/assistant_inbox.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/settings_spec.dart';
import 'package:illunis_client/app/spec_chat.dart';

import 'w5_fakes.dart';

void main() {
  group('noteSpecVersion', () {
    late FakeServerPort port;
    late InMemoryStateStore store;
    late ChatThread thread;
    Future<void> check() => noteSpecVersion(port, store, thread);
    List<String> said() => [for (final e in thread.entries) e.text];

    setUp(() {
      port = FakeServerPort()..fakeSpec = SettingsSpec.fromJson({'version': 3});
      store = InMemoryStateStore();
      thread = ChatThread();
    });

    test('the first read only stores the version', () async {
      await check();
      expect(said(), isEmpty);
      expect(await store.getString(StoreKeys.specVersion), '3');
    });

    test('the same version says nothing; a new one adds one line', () async {
      await check();
      await check();
      expect(said(), isEmpty);
      port.fakeSpec = SettingsSpec.fromJson({'version': 4});
      await check();
      await check();
      expect(said(), [SpecLine.changed(4)]);
    });

    test('relaunch with an older stored version adds one notice message after the last one', () async {
      await store.setString(StoreKeys.specVersion, '2');
      thread
        ..addUser('show my settings')
        ..addAssistant('Skills on: sleep. Settings version 2.');
      await check();
      await check();
      expect(said(), ['show my settings', 'Skills on: sleep. Settings version 2.', SpecLine.changed(3)]);
      expect(thread.entries.last.role, ChatRole.assistant);
    });
  });

  test('a spec_request becomes a card, not a spoken item', () async {
    final port = FakeServerPort();
    final thread = ChatThread();
    final flow = SpecChatFlow(server: port, thread: thread, log: (_) {});
    final sp = Speaker();
    final inbox = AssistantInbox(
      server: port,
      store: InMemoryStateStore(),
      speak: sp.speak,
      quiet: () => true,
      enabled: () => true,
      timer: FakeTimers().call,
      onSpecRequest: flow.proposeFromWords,
      log: (_) {},
    );
    port.inboxBatches.add(const InboxBatch(items: [
      InboxItem(id: 'a', kind: 'spec_request', text: 'turn off breathwork', ts: 1),
      InboxItem(id: 'b', kind: 'message', text: 'hi', ts: 2),
    ]));
    await inbox.poll();
    await flow.settled;
    expect(port.specProposeCalls, ['turn off breathwork']);
    expect(inbox.pending.map((i) => i.id), ['b']);
    expect(flow.openCardId, startsWith('spec:'));
    expect(thread.entries.last.text, startsWith(SpecLine.fromAssistant));
  });
}
