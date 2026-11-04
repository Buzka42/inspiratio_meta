import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/memory/assistant_memory_backend.dart';
import 'package:illunis_client/memory/local_memory_backend.dart';
import 'package:illunis_client/memory/memory_backend.dart';
import 'package:illunis_client/memory/memory_note.dart';

import '../app/memory_writer_test.dart' show FakeHttpClient;

// Long-term memory backends. Synthetic notes only.
const token = 'synthetic-device.c3ludGhldGljLWhtYWM';

MemoryNote note(String text, {double confidence = 0.8, DateTime? expiresAt, MemoryLabel label = MemoryLabel.note}) =>
    MemoryNote(text: text, label: label, confidence: confidence, expiresAt: expiresAt);

void main() {
  group('LocalMemoryBackend', () {
    late InMemoryStateStore store;
    late DateTime now;
    late LocalMemoryBackend b;

    setUp(() {
      store = InMemoryStateStore();
      now = DateTime.utc(2026, 10, 25, 9);
      b = LocalMemoryBackend(store, clock: () => now);
    });

    test('keyword recall ranks by overlap and leaves out unrelated notes', () async {
      await b.write(note('User said: I sleep badly after late zebra films'));
      await b.write(note('User said: my favourite breakfast is oats with quokka berries'));
      await b.write(note('User said: I walk the dog every evening'));
      final r = await b.recall('why do I sleep badly', k: 5);
      expect(r.map((m) => m.text), ['User said: I sleep badly after late zebra films']);
      final breakfast = await b.recall('ideas for breakfast oats');
      expect(breakfast.single.text, contains('oats'));
    });

    test('a prefix match counts ("sleeping" finds "sleep")', () async {
      await b.write(note('User said: I sleep badly after late zebra films'));
      expect(await b.recall('sleeping tips'), hasLength(1));
    });

    test('k caps the result, higher confidence first on equal overlap', () async {
      await b.write(note('zebra walk one', confidence: 0.5));
      await b.write(note('zebra walk two', confidence: 0.9));
      await b.write(note('zebra walk three', confidence: 0.7));
      final r = await b.recall('zebra walk', k: 2);
      expect(r.map((m) => m.text), ['zebra walk two', 'zebra walk three']);
      expect(await b.recall('zebra', k: 0), isEmpty);
      expect(await b.recall('the and of'), isEmpty); // Stop words only.
    });

    test('expired notes are never recalled or counted, and go on the next write', () async {
      await b.write(note('zebra observation', expiresAt: now.add(const Duration(days: 30))));
      await b.write(note('zebra lasting note'));
      expect(await b.recall('zebra'), hasLength(2));
      now = now.add(const Duration(days: 31));
      expect((await b.recall('zebra')).single.text, 'zebra lasting note');
      expect((await b.summary()).noteCount, 1);
      await b.write(note('quokka new note'));
      final stored = jsonDecode((await store.getString(StoreKeys.longTermMemory))!) as Map;
      expect((stored['notes'] as List).map((n) => n['text']), ['zebra lasting note', 'quokka new note']);
    });

    test('purgeExpired drops expired notes now', () async {
      await b.write(note('zebra soon gone', expiresAt: now.add(const Duration(hours: 1))));
      now = now.add(const Duration(hours: 2));
      expect(await b.purgeExpired(), 1);
      expect(await b.purgeExpired(), 0);
    });

    test('the same text replaces the older note; the cap drops the oldest', () async {
      final small = LocalMemoryBackend(store, clock: () => now, maxNotes: 2);
      await small.write(note('zebra a'));
      await small.write(note('Zebra A '));
      expect((await small.summary()).noteCount, 1);
      await small.write(note('zebra b'));
      await small.write(note('zebra c'));
      expect((await small.recall('zebra', k: 5)).map((m) => m.text).toSet(), {'zebra b', 'zebra c'});
    });

    test('notes survive a restart (a new instance on the same store)', () async {
      await b.write(note('quokka garden note', label: MemoryLabel.observation, confidence: 0.5));
      final again = LocalMemoryBackend(store, clock: () => now);
      final r = (await again.recall('garden')).single;
      expect((r.kind, r.confidence, r.source), ('hypothesis', 0.5, 'conversation'));
    });

    test('an unreadable store starts empty and is replaced on write', () async {
      await store.setString(StoreKeys.longTermMemory, '{not json');
      expect(await b.recall('zebra'), isEmpty);
      await b.write(note('zebra fresh'));
      expect(await LocalMemoryBackend(store, clock: () => now).recall('zebra'), hasLength(1));
    });

    test('summary speaks a count, never note text', () async {
      await b.write(note('User said: zebra secret'));
      final s = await b.summary();
      expect(s.spoken, 'I keep 1 note on this phone.');
      expect(s.spoken, isNot(contains('zebra')));
    });
  });

  group('VpsMemoryBackend', () {
    test('every call refuses with "not available yet"', () async {
      const v = VpsMemoryBackend();
      await expectLater(v.write(note('zebra')),
          throwsA(isA<MemoryUnavailable>().having((e) => e.message, 'message', 'not available yet')));
      await expectLater(v.recall('zebra'), throwsA(isA<MemoryUnavailable>()));
      expect((await v.summary()).available, isFalse);
    });
  });

  group('AssistantMemoryBackend', () {
    test('writes and recalls through the server port (fake)', () async {
      final server = FakeServerPort()
        ..assistantRecallResult = const [
          RecalledMemory(text: 'zebra one', kind: 'note', confidence: 0.8, source: 'hermes'),
          RecalledMemory(text: 'zebra two', kind: 'hypothesis', confidence: 0.5, source: 'hermes'),
        ];
      final a = AssistantMemoryBackend(server);
      await a.write(note('zebra written'));
      expect(server.assistantWrites.single.text, 'zebra written');
      expect(await a.recall('zebra', k: 1), hasLength(1));
      expect(server.assistantRecallCalls.single, (query: 'zebra', k: 1));
      expect(await a.recall('  '), isEmpty);
      expect(server.calls, isEmpty); // Voice-route order checks stay untouched.
    });

    test('HTTP: write posts MemoryNote.toJson to /assistant/memory/write', () async {
      final http = FakeHttpClient(response: {'ok': true});
      final a = AssistantMemoryBackend(HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http));
      await a.write(note('zebra http note'));
      final s = http.sent.single;
      expect(s.url.toString(), 'https://synthetic.invalid/assistant/memory/write');
      expect(jsonDecode(s.body.toString()), note('zebra http note').toJson());
    });

    test('HTTP: recall posts {query, k} and keeps only well-formed memories', () async {
      final http = FakeHttpClient(response: {
        'items': [
          {'text': 'zebra kept', 'kind': 'note', 'confidence': 0.8, 'source': 'hermes'},
          {'kind': 'note'}, // No text: dropped.
          'junk',
          {'text': 'zebra defaults'},
        ],
      });
      final a = AssistantMemoryBackend(HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http));
      final r = await a.recall('zebra question', k: 3);
      expect(http.sent.single.url.toString(), 'https://synthetic.invalid/assistant/memory/recall');
      expect(jsonDecode(http.sent.single.body.toString()), {'query': 'zebra question', 'k': 3});
      expect(r, const [
        RecalledMemory(text: 'zebra kept', kind: 'note', confidence: 0.8, source: 'hermes'),
        RecalledMemory(text: 'zebra defaults', kind: 'note', confidence: 0.5, source: 'unknown'),
      ]);
    });

    test('HTTP: a non-2xx recall fails with ServerException', () async {
      final http = FakeHttpClient(status: 502, response: {'error': 'upstream_error'});
      final a = AssistantMemoryBackend(HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http));
      await expectLater(a.recall('zebra'), throwsA(isA<ServerException>()));
    });
  });

  group('MemoryNote JSON', () {
    test('round-trips and rejects malformed entries', () {
      final n = note('zebra', expiresAt: DateTime.utc(2026, 11, 1), label: MemoryLabel.observation);
      final back = MemoryNote.fromJson(n.toJson())!;
      expect(back.toJson(), n.toJson());
      expect(MemoryNote.fromJson({'text': 'x', 'kind': 'fact', 'confidence': 1}), isNull);
      expect(MemoryNote.fromJson({'text': '', 'kind': 'note', 'confidence': 1}), isNull);
      expect(MemoryNote.fromJson({'text': 'x', 'kind': 'note', 'confidence': 1, 'expires_at': 'soon'}), isNull);
    });
  });
}
