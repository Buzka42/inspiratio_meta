// Settings through chat (PLAN-chat-settings.md WP1). Synthetic text.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/settings_spec.dart';
import 'package:illunis_client/app/spec_chat.dart';

class FakeTimer implements Timer {
  FakeTimer(this.d, this.f);
  final Duration d;
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

class Rig {
  Rig() {
    port.fakeClock = () => now;
    flow = SpecChatFlow(
      server: port,
      thread: thread,
      redispatch: redispatched.add,
      clock: () => now,
      timer: (d, f) => (timers..add(FakeTimer(d, f))).last,
      log: (_) {},
    );
  }
  final port = FakeServerPort();
  final thread = ChatThread();
  final timers = <FakeTimer>[];
  final redispatched = <String>[];
  var now = DateTime.utc(2026, 11, 3, 9);
  late final SpecChatFlow flow;

  /// A typed turn as submitTypedTurn makes it: the user bubble, then claim.
  Future<bool> type(String text) async {
    thread.addUser(text);
    final taken = flow.claim(text);
    await flow.settled;
    return taken;
  }

  List<ChatEntry> get offers => [for (final e in thread.entries) if (e.offer != null) e];
  String get lastText => thread.entries.last.text;
}

void main() {
  group('parseSpecIntent', () {
    for (final (text, want) in [
      ('turn off breathwork', SpecIntent.change),
      ('Turn breathwork on', SpecIntent.change),
      ('keep my memory in Hermes', SpecIntent.change),
      ('stop the morning note', SpecIntent.change),
      ('use nebius as the brain', SpecIntent.change),
      ('show my settings', SpecIntent.show),
      ('what can you do', SpecIntent.capabilities),
      ('add a source: Title', SpecIntent.addSource),
      ('remove the source leaflet', SpecIntent.removeSource),
      ('set up my assistant', SpecIntent.setup),
      ('link my bot', SpecIntent.link),
      ('I need to breathe', null),
      ('hello', null),
      ('stop', null),
      ('I slept badly', null),
    ]) {
      test('"$text" -> $want', () => expect(parseSpecIntent(text), want));
    }
  });

  test('"turn off breathwork" makes one card; Approve applies its change_id', () async {
    final r = Rig();
    expect(await r.type('turn off breathwork'), isTrue);
    expect(r.port.specProposeCalls, ['turn off breathwork']);
    final card = r.offers.single;
    expect(card.offer!.id, startsWith('spec:'));
    expect(card.offer!.isOpen, isTrue);
    expect(card.offer!.choices, ['Cancel', 'Approve']);
    expect(card.text, endsWith(SpecLine.ask));
    expect(r.timers.single.d, const Duration(minutes: 5));

    expect(await r.type('Approve'), isTrue);
    expect(r.port.specApplyCalls, [card.offer!.id.substring('spec:'.length)]);
    expect(r.port.fakeSpec.skills['breathwork'], isFalse);
    expect(r.offers.single.offer!.state, OfferState.accepted);
    expect(r.lastText, startsWith('Done: '));
    expect(r.timers.single.cancelled, isTrue);
  });

  test('"hello" makes no card and no propose call', () async {
    final r = Rig();
    expect(await r.type('hello'), isFalse);
    expect(r.port.specProposeCalls, isEmpty);
    expect(r.offers, isEmpty);
  });

  test('Cancel changes nothing', () async {
    final r = Rig();
    await r.type('turn off breathwork');
    expect(await r.type('Cancel'), isTrue);
    expect(r.port.specApplyCalls, isEmpty);
    expect(r.port.fakeSpec.skills['breathwork'], isTrue);
    expect(r.offers.single.offer!.state, OfferState.declined);
    expect(r.lastText, SpecLine.cancelled);
    expect(await r.type('Approve'), isFalse, reason: 'no card is open any more');
    expect(r.port.specApplyCalls, isEmpty);
  });

  test('another message closes the card and is left for normal handling', () async {
    final r = Rig();
    await r.type('turn off breathwork');
    expect(await r.type('hello'), isFalse);
    expect(r.offers.single.offer!.state, OfferState.declined);
    expect(r.port.fakeSpec.skills['breathwork'], isTrue);
  });

  test('an expired card is closed by its timer and applies nothing', () async {
    final r = Rig();
    await r.type('turn off breathwork');
    r.timers.single.fire();
    expect(r.offers.single.offer!.state, OfferState.closed);
    expect(r.lastText, SpecLine.expired);
    expect(await r.type('Approve'), isFalse);
    expect(r.port.specApplyCalls, isEmpty);
  });

  test('Approve after expiry (fake clock) gives no specApply', () async {
    final r = Rig();
    await r.type('turn off breathwork');
    r.now = r.now.add(const Duration(minutes: 6));
    expect(await r.type('Approve'), isTrue);
    expect(r.port.specApplyCalls, isEmpty);
    expect(r.lastText, SpecLine.expired);
    expect(r.port.fakeSpec.skills['breathwork'], isTrue);
  });

  for (final (e, line) in [
    (const ServerException(410, 'change_expired', null, 'change_expired'), SpecLine.expired),
    (const ServerException(409, 'change_unknown', null, 'change_unknown'), SpecLine.gone),
    (const ServerException(409, 'stale_version', null, 'stale_version'), SpecLine.stale),
  ]) {
    test('apply ${e.status} ${e.error} says so and changes nothing', () async {
      final r = Rig();
      await r.type('turn off breathwork');
      r.port.specApplyError = e;
      await r.type('Approve');
      expect(r.lastText, line);
      expect(r.port.fakeSpec.skills['breathwork'], isTrue);
      expect(r.offers.single.offer!.state, OfferState.closed);
    });
  }

  test('a refused change shows a plain sentence and no card', () async {
    final r = Rig();
    expect(await r.type('turn off the disclaimer memory'), isTrue);
    expect(r.offers, isEmpty);
    expect(r.lastText, SpecLine.couldNot);
  });

  for (final (Object e, line) in [
    (const SpecRefused([('spec_patch.guidelines', 'app_only')]), SpecLine.typeIt),
    (const SpecRefused([('crisis', 'guardrail')]), SpecLine.fixed),
    (const SpecRefused([('', 'no_change')]), 'Sleep is already on.'),
    (const ServerException(422, 'agent_refused', null, 'agent_refused'), SpecLine.declined),
    (const ServerException(503, 'spec_unavailable', null, 'spec_unavailable'), SpecLine.unreachable),
    (const ServerException(403, 'spec_forbidden', null, 'spec_forbidden'), SpecLine.forbidden),
    (const ServerException(422, 'too_large', null, 'too_large'), SpecLine.couldNot),
  ]) {
    test('refusal $e -> "$line"', () async {
      final r = Rig()..port.specProposeError = e;
      await r.type('turn off sleep');
      expect(r.offers, isEmpty);
      expect(r.lastText, line);
    });
  }

  for (final (text, line) in [
    ('keep my memory on the phone', 'Memory is already on the phone.'),
    ('turn on breathwork', 'Breathwork is already on.'),
    ('keep memory for 30 days', 'Memory is already kept for 30 days.'),
    ('use auto as the brain', 'The brain is already auto.'),
  ]) {
    test('no-op "$text" -> "$line", no card', () async {
      final r = Rig()..port.specProposeError = const ServerException(422, 'no_change', null, 'no_change');
      await r.type(text);
      expect(r.offers, isEmpty);
      expect(r.lastText, line);
    });
  }

  test('a no-op refusal list or an empty diff names the setting too', () async {
    final r = Rig();
    await r.type('turn on sleep');
    expect(r.lastText, 'Sleep is already on.');
    expect(alreadyLine('change that', const SettingsSpec()), isNull);
    expect(r.offers, isEmpty);
  });

  group('refusal code -> sentence', () {
    for (final (reason, line) in [
      ('no_change', SpecLine.already),
      ('app_only', SpecLine.typeIt),
      ('guardrail', SpecLine.fixed),
      ('unknown_key', SpecLine.notUnderstood),
      ('unknown_skill', SpecLine.notUnderstood),
      ('bad_value', SpecLine.notUnderstood),
      ('read_only', SpecLine.notUnderstood),
      ('forbidden_key', SpecLine.couldNot),
      ('crisis', SpecLine.couldNot),
      ('not_allowed', SpecLine.couldNot),
    ]) {
      test('$reason -> "$line"', () => expect(refusedLine([reason]), line));
    }
    test('not_understood without a normal turn -> ${SpecLine.notUnderstood}',
        () => expect(serverLine('not_understood'), SpecLine.notUnderstood));
    test('the code is logged, odd codes as other', () async {
      final logs = <String>[];
      final port = FakeServerPort()..specProposeError = const SpecRefused([('spec_patch.x', 'unknown_key')]);
      final thread = ChatThread();
      final flow = SpecChatFlow(server: port, thread: thread, log: logs.add)..claim('turn off sleep');
      await flow.settled;
      expect(logs, ['spec: refused reason=unknown_key']);
      expect(thread.entries.last.text, SpecLine.notUnderstood);
      expect(logCode('Not A Code'), 'other');
    });
  });

  test('not_understood goes on as a normal turn, once', () async {
    final r = Rig()..port.specProposeError = const ServerException(422, 'not_understood', null, 'not_understood');
    await r.type('keep my memory somewhere nice');
    expect(r.redispatched, ['keep my memory somewhere nice']);
    expect(r.flow.claim('keep my memory somewhere nice'), isFalse);
    expect(r.offers, isEmpty);
  });

  test('"show my settings" answers from the spec with no model call', () async {
    final r = Rig();
    expect(await r.type('show my settings'), isTrue);
    expect(r.port.specProposeCalls, isEmpty);
    expect(r.port.calls, isEmpty, reason: 'no /reply, /turn or /council');
    expect(r.lastText, contains('Skills on: breathwork, sleep, reading, habits.'));
    expect(r.lastText, contains('Memory stays on this phone for 30 days.'));
    expect(r.lastText, contains('Sleep hygiene leaflet'));
    expect(r.lastText, contains(FakeServerPort.fakeGuardrails.first));
  });

  test('"what can you do" lists the skills that are on', () async {
    final r = Rig();
    await r.type('what can you do');
    expect(r.lastText, startsWith('I can help with breathwork, sleep, reading, habits.'));
    expect(r.port.calls, isEmpty);
  });

  test('add a source in two messages, then Approve', () async {
    final r = Rig();
    await r.type('add a source');
    expect(r.lastText, SpecLine.pasteIt);
    await r.type('Evening notes\nRead before bed.');
    expect(r.offers.single.text, "Add 'Evening notes' (16 characters). ${SpecLine.ask}");
    await r.type('Approve');
    expect(r.port.fakeSources.map((s) => s.title), contains('Evening notes'));
  });

  test('remove the source by name', () async {
    final r = Rig();
    await r.type('remove the source leaflet');
    expect(r.offers.single.text, "Remove 'Sleep hygiene leaflet'. ${SpecLine.ask}");
    await r.type('Approve');
    expect(r.port.fakeSources, isEmpty);
  });

  test('the assistant\'s request makes the same card, led by its line', () async {
    final r = Rig();
    await r.flow.proposeFromWords('turn off sleep');
    expect(r.offers.single.text, startsWith(SpecLine.fromAssistant));
    expect(r.flow.openCardId, r.offers.single.offer!.id);
  });
}
