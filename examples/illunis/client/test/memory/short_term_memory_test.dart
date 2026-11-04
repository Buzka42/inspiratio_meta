import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/memory/short_term_memory.dart';

import '../app/memory_writer_test.dart' show FakeHttpClient;

// Short-term memory: turns plus the last N session summaries. Synthetic data.
const token = 'synthetic-device.c3ludGhldGljLWhtYWM';

void main() {
  late InMemoryStateStore store;
  late FakeServerPort server;
  late DateTime now;
  late List<String> logs;

  ShortTermMemory build({int n = defaultMaxSummaries}) => ShortTermMemory(
      store: store, summarise: server.sessionSummary, maxSummaries: n, clock: () => now, log: logs.add);

  setUp(() {
    store = InMemoryStateStore();
    server = FakeServerPort();
    now = DateTime.utc(2026, 10, 25, 9);
    logs = [];
  });

  Future<void> session(ShortTermMemory m, int i) async {
    server.sessionSummaryResult = 'summary $i';
    await m.addExchange(user: 'zebra question $i', assistant: 'quokka answer $i');
    now = now.add(const Duration(minutes: 5));
    await m.endSession();
  }

  test('a session sends its turns once and keeps only the summary', () async {
    final m = build();
    final start = now;
    await m.addExchange(user: 'zebra question', assistant: 'quokka answer');
    now = now.add(const Duration(minutes: 2));
    await m.addExchange(user: 'second zebra', assistant: 'second quokka');
    expect(m.turns, hasLength(4));
    await m.endSession();
    final call = server.sessionSummaryCalls.single;
    expect(call.turns.first, const SessionTurn('user', 'zebra question'));
    expect(call.turns[1].role, 'assistant');
    expect((call.startedAt, call.endedAt), (start, now));
    expect(m.turns, isEmpty);
    expect(m.summaries.single.text, 'Synthetic session summary.');
    await m.endSession(); // Nothing left: no second call.
    expect(server.sessionSummaryCalls, hasLength(1));
  });

  test('keeps the last 5 summaries by default (rotation)', () async {
    final m = build();
    for (var i = 1; i <= 7; i++) {
      await session(m, i);
    }
    expect(m.summaries.map((s) => s.text), ['summary 3', 'summary 4', 'summary 5', 'summary 6', 'summary 7']);
  });

  test('N is configurable, and lowering it drops the oldest at once', () async {
    final m = build(n: 3);
    for (var i = 1; i <= 4; i++) {
      await session(m, i);
    }
    expect(m.summaries.map((s) => s.text), ['summary 2', 'summary 3', 'summary 4']);
    m.maxSummaries = 1;
    await m.settled;
    expect(m.summaries.single.text, 'summary 4');
    final again = build(n: 10);
    await again.load();
    expect(again.summaries.single.text, 'summary 4');
  });

  test('a failed summary keeps the turns for the next attempt and logs a code only', () async {
    final m = build();
    server.sessionSummaryError = const ServerException(503, 'not_configured');
    await m.addExchange(user: 'zebra question', assistant: 'quokka answer');
    await m.endSession();
    expect(m.turns, hasLength(2));
    expect(m.summaries, isEmpty);
    expect(logs, ['memory: session_summary_failed']);
    server.sessionSummaryError = null;
    await m.endSession();
    expect(m.turns, isEmpty);
    expect(m.summaries, hasLength(1));
  });

  test('a turn after the session gap ends the old session first', () async {
    final m = build();
    await m.addExchange(user: 'zebra one', assistant: 'quokka one');
    now = now.add(const Duration(minutes: 10));
    await m.rollOverIfStale();
    expect(server.sessionSummaryCalls, isEmpty);
    now = now.add(const Duration(minutes: 31));
    await m.rollOverIfStale();
    expect(server.sessionSummaryCalls, hasLength(1));
  });

  test('turns and summaries survive a restart; long text is capped', () async {
    final m = build();
    await session(m, 1);
    await m.addExchange(user: List.filled(300, 'zebra').join(' '), assistant: 'quokka');
    final again = build();
    await again.load();
    expect(again.summaries.single.text, 'summary 1');
    expect(again.turns.first.text.length, lessThan(610));
    expect(again.startedAt, isNotNull);
  });

  test('turns are capped at maxTurns, newest kept', () async {
    final m = ShortTermMemory(store: store, summarise: server.sessionSummary, maxTurns: 4, clock: () => now);
    for (var i = 0; i < 5; i++) {
      await m.addExchange(user: 'zebra $i', assistant: 'quokka $i');
    }
    expect(m.turns.map((t) => t.text), ['zebra 3', 'quokka 3', 'zebra 4', 'quokka 4']);
  });

  test('context() is {summaries, turns} for /turn and /reply', () async {
    final m = build();
    await session(m, 1);
    await m.addExchange(user: 'zebra now', assistant: 'quokka now');
    expect(m.context().toJson(), {
      'summaries': ['summary 1'],
      'turns': [
        {'role': 'user', 'text': 'zebra now'},
        {'role': 'assistant', 'text': 'quokka now'},
      ],
    });
    expect(m.summaryText(), 'summary 1');
  });

  test('a malformed store loads as empty', () async {
    await store.setString(StoreKeys.shortTermMemory, '[1,2');
    final m = build();
    await m.load();
    expect(m.context().isEmpty, isTrue);
  });

  group('HttpServerPort.sessionSummary', () {
    test('posts {turns, started_at, ended_at} and returns {summary}', () async {
      final http = FakeHttpClient(response: {'summary': ' Talked about zebra sleep. '});
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      final s = await port.sessionSummary(
          turns: const [SessionTurn('user', 'zebra'), SessionTurn('assistant', 'quokka')],
          startedAt: DateTime.utc(2026, 10, 25, 8),
          endedAt: DateTime.utc(2026, 10, 25, 8, 20));
      expect(s, 'Talked about zebra sleep.');
      expect(http.sent.single.url.toString(), 'https://synthetic.invalid/session/summary');
      expect(jsonDecode(http.sent.single.body.toString()), {
        'turns': [
          {'role': 'user', 'text': 'zebra'},
          {'role': 'assistant', 'text': 'quokka'},
        ],
        'started_at': '2026-10-25T08:00:00.000Z',
        'ended_at': '2026-10-25T08:20:00.000Z',
      });
    });

    test('a missing summary is invalid_response', () async {
      final http = FakeHttpClient(response: {'other': 1});
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      await expectLater(
          port.sessionSummary(turns: const [SessionTurn('user', 'zebra')], startedAt: now, endedAt: now),
          throwsA(isA<ServerException>().having((e) => e.error, 'error', 'invalid_response')));
    });
  });
}
