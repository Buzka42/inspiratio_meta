import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/approval_flow.dart';
import 'package:illunis_client/app/assistant_bridge.dart';
import 'package:illunis_client/app/server_port.dart';

import 'w5_fakes.dart';

// Synthetic texts and ids only.
void main() {
  late FakeServerPort server;
  late Speaker sp;
  late FakeTimers timers;
  late ApprovalFlow approval;
  late bool linked;
  late List<(String, String)> exchanges;
  late AssistantBridge bridge;

  setUp(() {
    server = FakeServerPort();
    sp = Speaker();
    timers = FakeTimers();
    approval = ApprovalFlow(server: server, speak: sp.speak, timer: timers.call, log: (_) {});
    linked = true;
    exchanges = [];
    bridge = AssistantBridge(
      server: server,
      approval: approval,
      speak: sp.speak,
      linked: () => linked,
      context: () => 'User: synthetic',
      onExchange: (t, a) => exchanges.add((t, a)),
      log: (_) {},
    );
  });

  test('ask my assistant sends a message with the context and speaks the answer', () async {
    expect(bridge.claim('ask my assistant what is on tomorrow'), isTrue);
    await bridge.settled;
    expect(server.assistantMessages.single, (text: 'what is on tomorrow', context: 'User: synthetic'));
    expect(sp.spoken, [AssistantPrompt.asking, 'Synthetic assistant answer.']);
    expect(exchanges.single.$1, 'what is on tomorrow');
    expect(approval.busy, isFalse);
  });

  test('tell my coach bot goes to propose, then the readback; confirm only on yes', () async {
    expect(bridge.claim('tell my coach bot I will be late'), isTrue);
    await bridge.settled;
    expect(server.proposeCalls.single, 'tell my coach bot I will be late');
    expect(sp.spoken.last, 'I will message synthetic-bot: hello. Should I go ahead?');
    expect(approval.state, ApprovalState.listening);
    expect(server.confirmCalls, isEmpty);
    approval.claim('go ahead');
    await approval.settled;
    expect(server.confirmCalls.single, server.proposal.actionId);
  });

  test('a proposal returned with a message answer goes through approval too', () async {
    server.assistantReply = const AssistantReply(
        text: 'I can send that.',
        proposal: ActionProposal(actionId: 'act_0000000000000000000000000000000a', readback: 'I will message b: hi'));
    bridge.claim('ask my assistant if Ana is free');
    await bridge.settled;
    await approval.settled;
    expect(sp.spoken.skip(1), ['I can send that.', 'I will message b: hi. Should I go ahead?']);
    expect(approval.state, ApprovalState.listening);
    timers.fireActive();
    await approval.settled;
    expect(server.confirmCalls, isEmpty);
  });

  test('not linked: says so and calls nothing', () async {
    linked = false;
    expect(bridge.claim('ask my assistant what is on tomorrow'), isTrue);
    await bridge.settled;
    expect(sp.spoken, [AssistantPrompt.notLinked]);
    expect(server.calls, isEmpty);
  });

  test('a crisis refusal speaks the referral; a gate refusal a fixed line', () async {
    server.proposeError = const ActionRefused('crisis', referral: 'Synthetic referral.');
    bridge.claim('message my sister that I am late');
    await bridge.settled;
    expect(sp.spoken.last, 'Synthetic referral.');
    server.proposeError = const ActionRefused('gate');
    bridge.claim('message my sister that I am late');
    await bridge.settled;
    expect(sp.spoken.last, AssistantPrompt.notAllowed);
    expect(approval.busy, isFalse);
  });

  test('server failures map to fixed lines', () async {
    for (final (err, line) in [
      (const ServerException(403, 'assistant_not_linked'), AssistantPrompt.notLinked),
      (const ServerException(504, 'assistant_timeout'), AssistantPrompt.timeout),
      (const ServerException(502, 'assistant_unavailable'), AssistantPrompt.unavailable),
    ]) {
      server.messageError = err;
      bridge.claim('ask my assistant what is on tomorrow');
      await bridge.settled;
      expect(sp.spoken.last, line);
    }
    expect(exchanges, isEmpty);
  });

  test('other text is not claimed', () {
    expect(bridge.claim('what is the weather'), isFalse);
  });
}
