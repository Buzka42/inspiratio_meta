import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/server_port.dart';

// SSE parsing and POST /reply/stream over a loopback server shaped like
// server/src/reply-stream.js. Synthetic data only.

String sse(String event, Map<String, dynamic> data) => 'event: $event\ndata: ${jsonEncode(data)}\n\n';

void main() {
  group('parseSse', () {
    const body = 'event: sentence\ndata: {"text":"One."}\n\n'
        ': a comment\n'
        'event: done\ndata: {"text":"Two.",\ndata: "safety":"passed"}\n\n';
    const want = [
      SseEvent('sentence', '{"text":"One."}'),
      SseEvent('done', '{"text":"Two.",\n"safety":"passed"}'),
    ];

    test('whole body: events, comments skipped, multi-line data joined', () {
      expect(parseSse(body), want);
    });

    test('the same events for every split point', () {
      for (var i = 0; i <= body.length; i++) {
        final p = SseParser();
        expect([...p.add(body.substring(0, i)), ...p.add(body.substring(i)), ...p.close()], want,
            reason: 'split at $i');
      }
    });

    test('one character at a time, with CRLF and a CR LF split across chunks', () {
      final crlf = body.replaceAll('\n', '\r\n');
      final p = SseParser();
      final out = [for (final ch in crlf.split('')) ...p.add(ch), ...p.close()];
      expect(out, want);
    });

    test('missing final newline still yields the last event', () {
      expect(parseSse('event: done\ndata: {"text":"x"}'), [const SseEvent('done', '{"text":"x"}')]);
      expect(parseSse('event: done\ndata: {"text":"x"}\n'), [const SseEvent('done', '{"text":"x"}')]);
    });

    test('no event field means message; no data means no event', () {
      expect(parseSse('data: a\n\nevent: ping\n\n'), [const SseEvent('message', 'a')]);
      expect(parseSse('data:nospace\n\n'), [const SseEvent('message', 'nospace')]);
    });

    test('typed events', () {
      final events = [
        for (final e in parseSse([
          sse('sentence', {'text': 'A.'}),
          sse('done', {'text': 'B.', 'personality_id': 'p', 'safety': 'replaced', 'health': true}),
          sse('error', {'error': 'reply_timeout'}),
          sse('other', {}),
          'event: sentence\ndata: not json\n\n',
        ].join()))
          ReplyStreamEvent.fromSse(e),
      ];
      expect((events[0] as ReplySentence).text, 'A.');
      final d = events[1] as ReplyStreamDone;
      expect((d.text, d.personalityId, d.replaced, d.health), ('B.', 'p', true, true));
      expect((events[2] as ReplyStreamError).error, 'reply_timeout');
      expect(events[3], isNull);
      expect((events[4] as ReplyStreamError).error, 'invalid_event');
    });
  });

  group('HttpServerPort.replyStream', () {
    late HttpServer srv;
    late HttpServerPort port;
    final seen = <(String, Map<String, dynamic>, String?)>[];
    // Fake value for loopback tests only; not a real device token.
    const testToken = 'test-only-fake-device-token';
    // Each answer writes these pieces with a flush between them.
    late List<String> pieces;
    var status = 200;
    Completer<void>? hold;
    var closeEarly = false;

    setUp(() async {
      seen.clear();
      status = 200;
      hold = null;
      closeEarly = false;
      srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        seen.add(('${req.method} ${req.uri.path}', body, req.headers.value(HttpHeaders.acceptHeader)));
        final res = req.response..statusCode = status;
        if (status != 200) {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'error': 'not_found'}));
          return res.close();
        }
        res.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
        res.bufferOutput = false;
        for (final p in pieces) {
          res.write(p);
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await hold?.future;
        if (closeEarly) {
          // Drop the live connection mid-stream (headers already sent).
          await srv.close(force: true);
          return;
        }
        await res.close();
      });
      port = HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: testToken);
    });

    tearDown(() async {
      port.close();
      await srv.close(force: true);
    });

    Future<List<Object>> collect(Stream<ReplyStreamEvent> s) async {
      final out = <Object>[];
      try {
        await for (final e in s) {
          out.add(switch (e) {
            ReplySentence(:final text) => 'sentence:$text',
            ReplyStreamDone(:final text, :final safety) => 'done:$text:$safety',
            ReplyStreamError(:final error) => 'error:$error',
          });
        }
      } on ServerException catch (e) {
        out.add('throw:${e.status}:${e.error}');
      }
      return out;
    }

    test('posts {plan, transcript} to /reply/stream and yields events in order', () async {
      final all = sse('sentence', {'text': 'First sentence here.'}) +
          sse('sentence', {'text': 'Second sentence, zażółć.'}) +
          sse('done', {'text': 'Last.', 'personality_id': 'calm_guide', 'safety': 'passed', 'health': false});
      // Split mid-event and mid multi-byte character.
      final bytesAt = all.indexOf('ż') + 1;
      pieces = [all.substring(0, 10), all.substring(10, bytesAt), all.substring(bytesAt)];
      final got = await collect(port.replyStream(plan: const {'personality_id': 'calm_guide'}, transcript: 'hi'));
      expect(seen.single.$1, 'POST /reply/stream');
      expect(seen.single.$2, {
        'plan': {'personality_id': 'calm_guide'},
        'transcript': 'hi',
      });
      expect(seen.single.$3, 'text/event-stream');
      expect(got, [
        'sentence:First sentence here.',
        'sentence:Second sentence, zażółć.',
        'done:Last.:passed',
      ]);
    });

    test('error event is the last event', () async {
      pieces = [sse('sentence', {'text': 'Partial sentence.'}), sse('error', {'error': 'reply_upstream'})];
      expect(await collect(port.replyStream(plan: const {}, transcript: 'x')),
          ['sentence:Partial sentence.', 'error:reply_upstream']);
    });

    test('a stream that ends without done fails with stream_dropped', () async {
      pieces = [sse('sentence', {'text': 'Only one.'})];
      expect(await collect(port.replyStream(plan: const {}, transcript: 'x')),
          ['sentence:Only one.', 'throw:0:stream_dropped']);
    });

    test('a broken connection fails with stream_dropped', () async {
      pieces = [sse('sentence', {'text': 'Only one.'})];
      closeEarly = true;
      final got = await collect(port.replyStream(plan: const {}, transcript: 'x'));
      expect(got.last, 'throw:0:stream_dropped');
    });

    test('404 (route not deployed) fails with its status and code', () async {
      pieces = [];
      status = 404;
      expect(await collect(port.replyStream(plan: const {}, transcript: 'x')), ['throw:404:not_found']);
    });

    test('a cancelled token stops the read with code cancelled', () async {
      pieces = [sse('sentence', {'text': 'Before cancel.'})];
      hold = Completer<void>();
      final token = CancelToken();
      final got = <Object>[];
      final done = Completer<void>();
      port.replyStream(plan: const {}, transcript: 'x', cancel: token).listen(
          (e) {
            got.add(e);
            token.cancel();
          },
          onError: (Object e) => got.add(e),
          onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 5));
      expect(got.first, isA<ReplySentence>());
      expect(got.last, isA<ServerException>().having((e) => e.error, 'error', 'cancelled'));
      hold!.complete();
    });

    test('POST /reply is unchanged beside it', () async {
      // One JSON body: /reply still posts to /reply and parses JSON.
      pieces = [jsonEncode({'text': 'T.', 'personality_id': 'calm_guide'})];
      final r = await port.reply(plan: const {'personality_id': 'calm_guide'}, transcript: 'hi');
      expect(seen.single.$1, 'POST /reply');
      expect(seen.single.$3, isNot('text/event-stream'));
      expect(r.text, 'T.');
    });
  });
}
