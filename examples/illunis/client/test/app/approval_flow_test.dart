import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/approval_flow.dart';
import 'package:illunis_client/app/server_port.dart';

import 'w5_fakes.dart';

// Synthetic action ids and texts only.
const p = ActionProposal(actionId: 'act_0123456789abcdef0123456789abcdef', readback: 'I will message coach-bot: late');

void main() {
  late FakeServerPort server;
  late Speaker sp;
  late FakeTimers timers;
  late int listens;
  late ApprovalFlow flow;

  setUp(() {
    server = FakeServerPort()..outcome = ActionOutcome(actionId: p.actionId, status: 'done');
    sp = Speaker();
    timers = FakeTimers();
    listens = 0;
    flow = ApprovalFlow(server: server, speak: sp.speak, listen: () => listens++, timer: timers.call, log: (_) {});
  });

  Future<void> started() async {
    await flow.start(p);
    expect(flow.state, ApprovalState.listening);
  }

  test('reads the Worker readback back, then listens with an 8 s silence timer', () async {
    await started();
    expect(sp.spoken, ['I will message coach-bot: late. Should I go ahead?']);
    expect(listens, 1);
    expect(timers.active.single.after, const Duration(seconds: 8));
    expect(server.confirmCalls, isEmpty, reason: 'never auto-confirms');
  });

  for (final yes in ['yes', 'Do it.', 'go ahead', 'yes, go ahead please']) {
    test('"$yes" confirms with the action id only', () async {
      await started();
      expect(flow.claim(yes), isTrue);
      await flow.settled;
      expect(server.confirmCalls, [p.actionId]);
      expect(sp.spoken.last, ApprovalPrompt.done);
      expect(flow.state, ApprovalState.idle);
      expect(timers.all.single.cancelled, isTrue);
    });
  }

  for (final other in ['no', 'yes wait', "yes but don't", 'yeah', 'sure', 'send it to Leo instead', 'hmm']) {
    test('"$other" cancels and sends nothing', () async {
      await started();
      expect(flow.claim(other), isTrue);
      await flow.settled;
      expect(server.confirmCalls, isEmpty);
      expect(sp.spoken.last, ApprovalPrompt.cancelled);
      expect(flow.busy, isFalse);
      // A later yes is not taken: the action is gone.
      expect(flow.claim('yes'), isFalse);
      expect(server.confirmCalls, isEmpty);
    });
  }

  test('8 s of silence cancels; a yes after that is not taken', () async {
    await started();
    timers.fireActive();
    await flow.settled;
    expect(flow.busy, isFalse);
    expect(sp.spoken.last, ApprovalPrompt.cancelled);
    expect(flow.claim('yes'), isFalse);
    expect(server.confirmCalls, isEmpty);
  });

  test('an interrupted readback cancels without listening or confirming', () async {
    sp.results.add(false);
    await flow.start(p);
    expect(flow.busy, isFalse);
    expect(listens, 0);
    expect(timers.all, isEmpty);
    expect(flow.claim('yes'), isFalse);
    expect(server.confirmCalls, isEmpty);
  });

  test('speech during the readback cancels it', () async {
    final pending = flow.start(p);
    expect(flow.state, ApprovalState.reading);
    expect(flow.claim('yes'), isTrue);
    await pending;
    await flow.settled;
    expect(server.confirmCalls, isEmpty);
    expect(flow.busy, isFalse);
    expect(sp.spoken.last, ApprovalPrompt.cancelled);
  });

  for (final status in [410, 404]) {
    test('confirm answered $status says it expired', () async {
      server.confirmError = ServerException(status, status == 410 ? 'action_expired' : 'action_unknown');
      await started();
      flow.claim('yes');
      await flow.settled;
      expect(server.confirmCalls, [p.actionId]);
      expect(sp.spoken.last, ApprovalPrompt.expired);
      expect(flow.busy, isFalse);
    });
  }

  test('queued, failed and a network error each have their own line', () async {
    for (final (setUpCase, line) in [
      (() => server.outcome = ActionOutcome(actionId: p.actionId, status: 'queued'), ApprovalPrompt.queued),
      (() => server.outcome = ActionOutcome(actionId: p.actionId, status: 'failed'), ApprovalPrompt.failed),
      (() => server.confirmError = const ServerException(502, 'assistant_unavailable'), ApprovalPrompt.unknownResult),
    ]) {
      setUpCase();
      await started();
      flow.claim('do it');
      await flow.settled;
      expect(sp.spoken.last, line);
    }
  });

  test('a new proposal replaces a waiting one, which is never confirmed', () async {
    await started();
    const q = ActionProposal(actionId: 'act_ffffffffffffffffffffffffffffffff', readback: 'I will message b: x');
    await flow.start(q);
    flow.claim('yes');
    await flow.settled;
    expect(server.confirmCalls, [q.actionId]);
  });

  test('approvalPrompt joins with one full stop', () {
    expect(approvalPrompt('I will message a: hi.'), 'I will message a: hi. Should I go ahead?');
    expect(approvalPrompt('I will message a: hi'), 'I will message a: hi. Should I go ahead?');
  });
}
