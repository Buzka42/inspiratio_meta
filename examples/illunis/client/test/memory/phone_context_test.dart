import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/memory_writer.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/memory/local_memory_backend.dart';
import 'package:illunis_client/memory/memory_backend.dart';
import 'package:illunis_client/memory/memory_note.dart';
import 'package:illunis_client/memory/phone_context.dart';
import 'package:illunis_client/memory/short_term_memory.dart';
import 'package:illunis_client/voice/voice_session.dart';

import '../app/memory_writer_test.dart' show FakeHttpClient;

// /turn and /reply carry the phone's short-term context and recalled notes.
// Synthetic data only; "zebra" and "quokka" mark any leak into logs.
const token = 'synthetic-device.c3ludGhldGljLWhtYWM';
const answer = 'Try a short walk. Then rest.';

class _SlowBackend implements MemoryBackend {
  @override
  String get id => 'assistant';
  @override
  Future<void> write(MemoryNote note) async {}
  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) =>
      Completer<List<RecalledMemory>>().future; // Never answers.
  @override
  Future<MemorySummary> summary() async => MemorySummary(backend: id);
}

void main() {
  late FakeServerPort server;
  late InMemoryStateStore store;
  late List<String> logs;
  late List<TurnRequest> turns;
  late DateTime now;

  AppController build({MemoryBackend? backend, ShortTermMemory? shortTerm, bool stream = true}) {
    final c = AppController(
      fog: FogSettings(InMemoryKeyValueStore()),
      server: server,
      tts: SilentTts(),
      log: logs.add,
      streamReplies: stream,
      memory: MemoryWriter(backend ?? LocalMemoryBackend(store, clock: () => now), log: logs.add, clock: () => now),
      shortTerm: shortTerm,
      recallTimeout: const Duration(milliseconds: 50),
    );
    c.turnRequests.listen(turns.add);
    return c;
  }

  Future<void> ask(AppController c, String text) async {
    c.dispatch(const WakeWordHeard());
    c.dispatch(UserSpeechEnded(text));
    await c.routeTurn(turns.last);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    server = FakeServerPort(replyResult: const ReplyResult(text: answer, personalityId: 'calm_guide'));
    store = InMemoryStateStore();
    logs = [];
    turns = [];
    now = DateTime.utc(2026, 10, 25, 9);
  });

  test('with nothing remembered the bodies stay as before (no phone context)', () async {
    final c = build();
    await ask(c, 'tell me something about zebra');
    expect(server.turnPhones.single, isNull);
    expect(server.replyPhones.single, isNull);
  });

  test('recalled notes and short-term turns go with /turn and /reply/stream', () async {
    final local = LocalMemoryBackend(store, clock: () => now);
    await local.write(const MemoryNote(text: 'User said: I sleep badly after zebra films', label: MemoryLabel.note, confidence: 0.8));
    final st = ShortTermMemory(store: store, summarise: server.sessionSummary, clock: () => now, log: logs.add);
    final c = build(backend: local, shortTerm: st);

    await ask(c, 'why do I sleep so badly');
    final p1 = server.turnPhones.single!;
    expect(p1.memories.single.text, contains('zebra films'));
    expect(p1.shortTerm.turns, isEmpty);
    expect(identical(server.replyPhones.single, p1), isTrue);

    await st.settled;
    await ask(c, 'and what about the weekend');
    final p2 = server.turnPhones.last!;
    expect(p2.shortTerm.turns.map((t) => (t.role, t.text)), [
      ('user', 'why do I sleep so badly'),
      ('assistant', answer),
    ]);
  });

  test('the plain /reply path carries it too', () async {
    final st = ShortTermMemory(store: store, summarise: server.sessionSummary, clock: () => now);
    await st.addExchange(user: 'zebra earlier', assistant: 'quokka earlier');
    final c = build(shortTerm: st, stream: false);
    await ask(c, 'tell me more please now');
    expect(server.calls, ['/turn', '/reply']);
    expect(server.replyPhones.single!.shortTerm.turns, hasLength(2));
  });

  test('a crisis turn is not added to the short-term turns', () async {
    server.turnResult = const TurnPlan(crisis: true, escalate: true, response: 'Synthetic referral.');
    final st = ShortTermMemory(store: store, summarise: server.sessionSummary, clock: () => now);
    final c = build(shortTerm: st);
    await ask(c, 'synthetic crisis words here');
    await st.settled;
    expect(st.turns, isEmpty);
  });

  test('a slow recall is skipped after the timeout, logged as a code', () async {
    final c = build(backend: _SlowBackend());
    await ask(c, 'zebra quokka question');
    expect(server.calls, ['/turn', '/reply/stream']);
    expect(logs, ['memory: recall_failed code=timeout']);
  });

  test('a refusing backend (VPS) logs its code and the turn goes on', () async {
    final c = build(backend: const VpsMemoryBackend());
    await ask(c, 'zebra quokka question');
    expect(server.calls, ['/turn', '/reply/stream']);
    expect(logs, contains('memory: recall_failed code=vps_not_available'));
    expect(logs.join(' '), isNot(contains('zebra')));
  });

  test('a stale session is summarised before the new turn is recorded', () async {
    final st = ShortTermMemory(store: store, summarise: server.sessionSummary, clock: () => now);
    await st.addExchange(user: 'zebra old', assistant: 'quokka old');
    now = now.add(const Duration(hours: 2));
    final c = build(shortTerm: st);
    await ask(c, 'a brand new question today');
    await st.settled;
    expect(server.sessionSummaryCalls.single.turns.first.text, 'zebra old');
    expect(st.summaries.single.text, 'Synthetic session summary.');
    expect(st.turns.first.text, 'a brand new question today');
  });

  group('HTTP bodies', () {
    const phone = PhoneContext(
      shortTerm: ShortTermContext(summaries: ['zebra summary'], turns: [SessionTurn('user', 'quokka turn')]),
      memories: [RecalledMemory(text: 'zebra note', kind: 'note', confidence: 0.8, source: 'conversation')],
    );
    const expected = {
      'short_term': {
        'summaries': ['zebra summary'],
        'turns': [
          {'role': 'user', 'text': 'quokka turn'},
        ],
      },
      'memories': [
        {'text': 'zebra note', 'kind': 'note', 'confidence': 0.8, 'source': 'conversation'},
      ],
    };

    test('/turn adds short_term and memories at the top level', () async {
      final http = FakeHttpClient(response: {'personality_id': 'calm_guide'});
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      await port.turn(transcript: 'zebra', phone: phone);
      expect(jsonDecode(http.sent.single.body.toString()), {'transcript': 'zebra', 'context': {}, ...expected});
    });

    test('/reply adds them beside plan and transcript; without phone the body is unchanged', () async {
      final http = FakeHttpClient(response: {'text': 'ok'});
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      await port.reply(plan: const {'personality_id': 'calm_guide'}, transcript: 'zebra', phone: phone);
      final body = jsonDecode(http.sent.single.body.toString()) as Map;
      expect(body, {'plan': {'personality_id': 'calm_guide'}, 'transcript': 'zebra', ...expected});
      expect((body['plan'] as Map).containsKey('memories'), isFalse); // Never inside plan.
      await port.reply(plan: const {'personality_id': 'calm_guide'}, transcript: 'zebra');
      expect(jsonDecode(http.sent.last.body.toString()), {'plan': {'personality_id': 'calm_guide'}, 'transcript': 'zebra'});
    });
  });
}
