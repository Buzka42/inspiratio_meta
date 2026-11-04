import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/memory/phone_context.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Synthetic fixtures only. Distinct marker words let the log check find leaks.
const transcript = 'zebra transcript about quokka plans';
const replyText = 'Walk 3.5 km with Dr. Lee. Drink water! Rest after?';
const referral = 'Synthetic referral text. Please call a helpline.';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeServerPort server;
  late FakeTtsEngine engine;
  late AppController c;
  late List<TurnRequest> turns;
  late List<String> logs;
  late List<(VoiceState, String?)> seen;

  setUp(() {
    server = FakeServerPort(
        turnResult: const TurnPlan(personalityId: 'calm_guide', skillId: 'habit_building'),
        replyResult: const ReplyResult(text: replyText, personalityId: 'calm_guide'));
    engine = FakeTtsEngine();
    logs = [];
    c = AppController(
      fog: FogSettings(InMemoryKeyValueStore()),
      server: server,
      tts: SilentTts(),
      speech: SpeechOutput(engine, log: logs.add),
      log: logs.add,
      streamReplies: false, // This file covers the POST /reply path.
    );
    turns = [];
    c.turnRequests.listen(turns.add);
    seen = [];
    c.addListener(() => seen.add((c.voice, c.caption)));
  });

  void ask([String text = transcript]) {
    c.dispatch(const WakeWordHeard());
    c.dispatch(UserSpeechEnded(text));
  }

  test('normal reply: /turn first, then /reply with its plan; sentences in order', () async {
    ask();
    await c.routeTurn(turns.single);

    expect(server.calls, ['/turn', '/reply']);
    expect(server.turnCalls.single.transcript, transcript);
    expect(server.turnCalls.single.context, isEmpty);

    final call = server.replyCalls.single;
    expect(call.transcript, transcript);
    expect(call.plan['personality_id'], 'calm_guide');
    expect(call.plan['skill_id'], 'habit_building');

    const sentences = ['Walk 3.5 km with Dr. Lee.', 'Drink water!', 'Rest after?'];
    expect(engine.played, sentences);
    // One ReplyChunk per sentence (caption follows each), then ReplyDone.
    final captions = [for (final s in seen) if (s.$1 == VoiceState.speaking) s.$2];
    expect(captions.toSet().toList(), sentences);
    expect(seen.last.$1, VoiceState.idle);
    expect(c.voice, VoiceState.idle);
  });

  test('barge-in mid reply cancels speech and drops the rest', () async {
    engine.autoFinish = false;
    ask();
    final done = c.routeTurn(turns.single);
    await settle();
    expect(c.voice, VoiceState.speaking);
    expect(engine.trace.where((t) => t.startsWith('play:')), ['play:Walk 3.5 km with Dr. Lee.']);

    c.dispatch(const BargeIn());
    await done;
    await settle();
    expect(c.voice, VoiceState.listening); // Not idle: the user is talking.
    expect(engine.stops, greaterThanOrEqualTo(1));
    expect(engine.played, isEmpty);
    expect(engine.trace.where((t) => t.startsWith('play:')).length, 1);
    expect(logs, isEmpty);
  });

  test('barge-in while the reply request is pending cancels it and drops it', () async {
    server.replyGate = Completer<void>();
    ask();
    final done = c.routeTurn(turns.single);
    await settle();
    expect(server.replyCalls, hasLength(1));
    expect(c.voice, VoiceState.thinking);

    c.dispatch(const BargeIn());
    expect(server.replyCancels, 1);
    server.replyGate!.complete(); // A late answer must not be spoken.
    await done;
    await settle();
    expect(engine.trace, isEmpty);
    expect(c.voice, VoiceState.listening);
    expect(logs, isEmpty); // Cancelled is not an error.
  });

  test('barge-in while /turn is pending cancels it and never calls /reply', () async {
    server.turnGate = Completer<void>();
    ask();
    final done = c.routeTurn(turns.single);
    await settle();
    expect(server.calls, ['/turn']);
    expect(c.voice, VoiceState.thinking);

    c.dispatch(const BargeIn());
    expect(server.turnCancels, 1);
    server.turnGate!.complete(); // A late plan must not reach /reply.
    await done;
    await settle();
    expect(server.calls, ['/turn']);
    expect(server.replyCalls, isEmpty);
    expect(c.lastPlan, isNull);
    expect(engine.trace, isEmpty);
    expect(c.voice, VoiceState.listening);
    expect(logs, isEmpty);
  });

  test('crisis: referral spoken from /turn, /reply never called', () async {
    server.turnResult = const TurnPlan(crisis: true, escalate: true, response: referral);
    ask('synthetic crisis phrase');
    await c.routeTurn(turns.single);
    expect(server.calls, ['/turn']);
    expect(server.replyCalls, isEmpty);
    expect(engine.played, ['Synthetic referral text.', 'Please call a helpline.']);
    expect(c.voice, VoiceState.idle);
  });

  test('reply error speaks the fixed fallback and returns to idle', () async {
    server.replyError = const ServerException(502, 'upstream_error', 'quokka detail');
    ask();
    await c.routeTurn(turns.single);
    expect(engine.played, [replyFallbackText]);
    expect(c.caption, replyFallbackText);
    expect(c.voice, VoiceState.idle);
    expect(logs, ['reply: failed code=upstream_error']);
  });

  test('turn error and empty reply also fall back', () async {
    final failing = _RouteFails(logs);
    final d = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: failing,
        tts: SilentTts(),
        speech: SpeechOutput(engine, log: logs.add),
        log: logs.add,
        streamReplies: false);
    final t = <TurnRequest>[];
    d.turnRequests.listen(t.add);
    d.dispatch(const WakeWordHeard());
    d.dispatch(const UserSpeechEnded(transcript));
    await d.routeTurn(t.single);
    expect(failing.replyCalls, isEmpty);
    expect(engine.played, [replyFallbackText]);
    expect(d.voice, VoiceState.idle);

    server.replyResult = const ReplyResult(text: '  ');
    ask();
    await c.routeTurn(turns.single);
    expect(engine.played, [replyFallbackText, replyFallbackText]);
    expect(logs, ['reply: turn_failed code=reply_error', 'reply: failed code=empty_reply']);
  });

  test('no log line carries reply or transcript text', () async {
    // Normal, failing and crisis turns, plus a speech failure, all logged.
    ask();
    await c.routeTurn(turns.last);
    server.turnError = StateError('$replyText $transcript');
    ask();
    await c.routeTurn(turns.last);
    server.turnError = const ServerException(502, 'upstream_error', 'quokka detail');
    ask();
    await c.routeTurn(turns.last);
    server.turnError = null;
    server.replyError = StateError('$replyText $transcript');
    ask();
    await c.routeTurn(turns.last);
    server.replyError = null;
    engine.failOn = 'Drink water!';
    ask();
    await c.routeTurn(turns.last);
    server.turnResult = const TurnPlan(crisis: true, response: referral);
    ask();
    await c.routeTurn(turns.last);

    expect(logs, isNotEmpty);
    expect(logs, contains('reply: turn_failed code=reply_error'));
    for (final line in logs) {
      for (final word in ['zebra', 'quokka', 'Walk', 'water', 'Rest', 'referral', 'helpline']) {
        expect(line.contains(word), isFalse, reason: 'log leaked text: $line');
      }
    }
  });
}

class _RouteFails extends FakeServerPort {
  _RouteFails(this.logs);
  final List<String> logs;
  @override
  Future<TurnPlan> turn({
    required String transcript,
    Map<String, dynamic> context = const {},
    PhoneContext? phone,
    CancelToken? cancel,
  }) async =>
      throw StateError('quokka');
}
