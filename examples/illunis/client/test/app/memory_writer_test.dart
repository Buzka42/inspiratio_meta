import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/memory_writer.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/memory/assistant_memory_backend.dart';
import 'package:illunis_client/memory/memory_backend.dart';
import 'package:illunis_client/memory/memory_note.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Memory write after a turn. Synthetic data only; marker words (zebra,
// quokka) let the log checks find any transcript leak.
const statement = 'I sleep badly after zebra quokka evenings';
const question = 'what should zebra quokka eat for breakfast today';
const answer = 'Try oats with fruit. Add some yoghurt if you like.';
const referral = 'Synthetic referral text.';
final now = DateTime.utc(2026, 10, 25, 9);

// ---- Fake dart:io HttpClient: records each request, answers a fixed status.

class _Sent {
  String? method;
  Uri? url;
  final headers = <String, String>{};
  final body = StringBuffer();
}

class FakeHttpClient implements HttpClient {
  FakeHttpClient({this.status = 200, this.response = const {'id': 'synthetic-id'}});
  int status;
  Object response;
  final sent = <_Sent>[];

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final s = _Sent()
      ..method = 'POST'
      ..url = url;
    sent.add(s);
    return _FakeRequest(s, this);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders(this.s);
  final _Sent s;

  @override
  set contentType(ContentType? v) => s.headers['content-type'] = '$v';

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => s.headers[name] = '$value';

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.s, this.client);
  final _Sent s;
  final FakeHttpClient client;

  @override
  HttpHeaders get headers => _FakeHeaders(s);

  @override
  void write(Object? o) => s.body.write(o);

  @override
  Future<HttpClientResponse> close() async =>
      _FakeResponse(client.status, utf8.encode(jsonEncode(client.response)));

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.bytes);
  @override
  final int statusCode;
  final List<int> bytes;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// Records writes; recall returns nothing.
class RecordingBackend implements MemoryBackend {
  final writes = <MemoryNote>[];
  Object? writeError;

  @override
  String get id => 'phone';
  @override
  Future<void> write(MemoryNote note) async {
    final e = writeError;
    if (e != null) throw e;
    writes.add(note);
  }

  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) async => const [];
  @override
  Future<MemorySummary> summary() async => MemorySummary(backend: id, noteCount: writes.length);
}

void main() {
  group('noteForTurn', () {
    test('a statement about the user is a note in their words, 0.8, no expiry', () {
      final n = noteForTurn(transcript: statement, answer: answer, now: now)!;
      expect(n.toJson(), {
        'text': 'User said: $statement',
        'kind': 'note',
        'source': 'conversation',
        'confidence': 0.8,
        'expires_at': null,
      });
    });

    test('anything else is an observation, 0.5, expiring in 30 days', () {
      final n = noteForTurn(transcript: question, answer: answer, now: now)!;
      final j = n.toJson();
      expect(j['kind'], 'hypothesis'); // Shown to the model as "observation".
      expect(n.label, MemoryLabel.observation);
      expect(j['confidence'], 0.5);
      expect(j['source'], 'conversation');
      expect(j['expires_at'], '2026-11-24T09:00:00.000Z');
      // One short note: the first answer sentence only, never the whole reply.
      expect(j['text'], 'User asked: $question Illunis answered: Try oats with fruit.');
      expect(j['text'], isNot(contains('yoghurt')));
    });

    test('a question with "I" in it is still an observation', () {
      final n = noteForTurn(transcript: 'should I walk more after lunch', answer: answer, now: now)!;
      expect(n.label, MemoryLabel.observation);
    });

    test('long input is capped, never stored whole', () {
      final long = List.filled(80, 'zebra').join(' ');
      final s = noteForTurn(transcript: 'I think $long', answer: answer, now: now)!;
      expect(s.text.length, lessThan(220));
      final q = noteForTurn(transcript: 'what about $long', answer: '$long.', now: now)!;
      expect(q.text.length, lessThan(300));
    });

    test('no label is ever "fact"', () {
      for (final t in [statement, question, 'tell me about zebra quokka things']) {
        expect(noteForTurn(transcript: t, answer: answer, now: now)!.toJson()['kind'], isNot('fact'));
      }
    });

    test('crisis, safety-replaced and short turns produce nothing', () {
      expect(noteForTurn(transcript: statement, answer: answer, now: now, crisis: true), isNull);
      expect(noteForTurn(transcript: statement, answer: answer, now: now, replaced: true), isNull);
      expect(noteForTurn(transcript: 'I am tired', answer: answer, now: now), isNull); // 3 words.
      expect(noteForTurn(transcript: question, answer: '  ', now: now), isNull);
    });
  });

  group('AssistantMemoryBackend over HttpServerPort with a fake HTTP client', () {
    const token = 'synthetic-device.c3ludGhldGljLWhtYWM';

    test('posts the note as /assistant/memory/write expects it', () async {
      final http = FakeHttpClient();
      final port = HttpServerPort('https://synthetic.invalid/', deviceToken: token, client: http);
      final logs = <String>[];
      final w = MemoryWriter(AssistantMemoryBackend(port), log: logs.add, clock: () => now);
      expect(await w.afterTurn(transcript: question, answer: answer), isTrue);
      final s = http.sent.single;
      expect(s.url.toString(), 'https://synthetic.invalid/assistant/memory/write');
      expect(s.headers[HttpHeaders.authorizationHeader], 'Bearer $token');
      final body = jsonDecode(s.body.toString()) as Map<String, dynamic>;
      expect(body['kind'], 'hypothesis');
      expect(body['confidence'], 0.5);
      expect(body['expires_at'], '2026-11-24T09:00:00.000Z');
      expect(body['source'], 'conversation');
      expect(logs, isEmpty);
    });

    test('a user statement posts note, 0.8, no expiry', () async {
      final http = FakeHttpClient();
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      await MemoryWriter(AssistantMemoryBackend(port), log: (_) {}, clock: () => now).afterTurn(transcript: statement, answer: answer);
      final body = jsonDecode(http.sent.single.body.toString()) as Map<String, dynamic>;
      expect((body['kind'], body['confidence'], body['expires_at'], body['source']),
          ('note', 0.8, null, 'conversation'));
    });

    test('a 503 is swallowed and logged as the fixed code only', () async {
      final http = FakeHttpClient(
          status: 503, response: {'error': 'not_configured', 'detail': 'MEMORY_PROVIDER unknown'});
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      final logs = <String>[];
      final ok = await MemoryWriter(AssistantMemoryBackend(port), log: logs.add, clock: () => now)
          .afterTurn(transcript: statement, answer: answer);
      expect(ok, isFalse);
      expect(http.sent, hasLength(1));
      expect(logs, ['memory_write_failed']);
      for (final l in logs) {
        expect(l, isNot(contains('zebra')));
        expect(l, isNot(contains('quokka')));
        expect(l, isNot(contains('503')));
      }
    });

    test('crisis and short turns send no request', () async {
      final http = FakeHttpClient();
      final port = HttpServerPort('https://synthetic.invalid', deviceToken: token, client: http);
      final w = MemoryWriter(AssistantMemoryBackend(port), log: (_) {}, clock: () => now);
      expect(await w.afterTurn(transcript: statement, answer: answer, crisis: true), isFalse);
      expect(await w.afterTurn(transcript: statement, answer: answer, replaced: true), isFalse);
      expect(await w.afterTurn(transcript: 'zebra quokka now', answer: answer), isFalse);
      expect(http.sent, isEmpty);
    });
  });

  group('AppController writes after a completed turn', () {
    late FakeServerPort server;
    late RecordingBackend backend;
    late SilentTts tts;
    late AppController c;
    late List<TurnRequest> turns;
    late List<String> logs;

    AppController build({bool stream = true}) {
      final ctl = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: server,
        tts: tts,
        log: logs.add,
        streamReplies: stream,
        memory: MemoryWriter(backend, log: logs.add, clock: () => now),
      );
      ctl.turnRequests.listen(turns.add);
      return ctl;
    }

    setUp(() {
      server = FakeServerPort(replyResult: const ReplyResult(text: answer, personalityId: 'calm_guide'));
      backend = RecordingBackend();
      tts = SilentTts();
      turns = [];
      logs = [];
      c = build();
    });

    Future<void> ask(String text) async {
      c.dispatch(const WakeWordHeard());
      c.dispatch(UserSpeechEnded(text));
      await c.routeTurn(turns.last);
      await Future<void>.delayed(Duration.zero);
    }

    test('a streamed turn stores one note', () async {
      await ask(statement);
      expect(tts.spoken.join(' '), answer); // Spoken sentence by sentence.
      final n = backend.writes.single;
      expect((n.label, n.confidence, n.expiresAt, n.source), (MemoryLabel.note, 0.8, null, 'conversation'));
      expect(server.calls, ['/turn', '/reply/stream']);
      expect(server.memoryWrites, isEmpty); // The backend, never /memory/write.
    });

    test('a non-streamed turn stores one observation', () async {
      c = build(stream: false);
      await ask(question);
      final n = backend.writes.single;
      expect((n.label, n.confidence), (MemoryLabel.observation, 0.5));
      expect(n.expiresAt, now.add(const Duration(days: 30)));
    });

    test('a crisis turn writes nothing', () async {
      server.turnResult = const TurnPlan(crisis: true, escalate: true, response: referral);
      await ask(statement);
      expect(tts.spoken, [referral]);
      expect(backend.writes, isEmpty);
    });

    test('a safety-replaced reply writes nothing (stream and plain)', () async {
      server.replyStreamEvents = [const ReplyStreamDone(text: referral, safety: 'replaced')];
      await ask(statement);
      c = build(stream: false);
      server.replyResult = const ReplyResult(text: referral, safety: 'replaced');
      await ask(statement);
      expect(tts.spoken, [referral, referral]);
      expect(backend.writes, isEmpty);
    });

    test('a short turn writes nothing', () async {
      await ask('I feel tired');
      expect(tts.spoken.join(' '), answer); // Spoken sentence by sentence.
      expect(backend.writes, isEmpty);
    });

    test('a failed reply writes nothing', () async {
      server.replyStreamError = const ServerException(502, 'upstream_error');
      await ask(statement);
      expect(tts.spoken, [replyFallbackText]);
      expect(backend.writes, isEmpty);
    });

    test('a failing write never blocks speech and logs the code only', () async {
      backend.writeError = const ServerException(503, 'not_configured', 'MEMORY_PROVIDER unknown');
      await ask(statement);
      expect(tts.spoken.join(' '), answer); // Spoken sentence by sentence.
      expect(c.voice, VoiceState.idle);
      expect(logs, ['memory_write_failed']);
      expect(logs.join(' '), isNot(contains('zebra')));
    });
  });
}
