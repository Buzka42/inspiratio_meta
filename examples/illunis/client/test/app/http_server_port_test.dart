import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/settings_spec.dart';

// Loopback server that records requests and answers with canned JSON shaped
// like server/src. Synthetic data only.
void main() {
  late HttpServer srv;
  late HttpServerPort port;
  final seen = <(String, Map<String, dynamic>)>[];
  final auth = <String?>[];
  // Synthetic token, shaped like server/src/auth.js `<deviceId>.<hmac>`.
  const token = 'synthetic-device.c3ludGhldGljLWhtYWM';
  var status = 200;
  Object reply = {};

  setUp(() async {
    seen.clear();
    auth.clear();
    status = 200;
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      seen.add(('${req.method} ${req.uri.path}', body));
      auth.add(req.headers.value(HttpHeaders.authorizationHeader));
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply));
      await req.response.close();
    });
    port = HttpServerPort('http://127.0.0.1:${srv.port}/', deviceToken: token);
  });

  tearDown(() async {
    port.close();
    await srv.close(force: true);
  });

  test('router', () async {
    reply = {'personality_id': 'coach', 'skill_id': 'training', 'escalate': false};
    final r = await port.route('workout today');
    expect(seen.single.$1, 'POST /router');
    expect(seen.single.$2, {'transcript': 'workout today'});
    expect((r.personalityId, r.skillId, r.escalate, r.crisis), ('coach', 'training', false, false));
  });

  test('router crisis', () async {
    reply = {'crisis': true, 'personality_id': null, 'skill_id': null, 'escalate': true, 'response': 'R'};
    final r = await port.route('x');
    expect((r.crisis, r.response, r.personalityId), (true, 'R', null));
  });

  test('digest', () async {
    reply = {'text': 'T', 'health': true, 'disclaimer': 'D'};
    final d = await port.digest(
        personalityId: 'coach', skillPackId: 'training', findings: const [Finding('f', kind: 'health')]);
    expect(seen.single.$1, 'POST /digest');
    expect(seen.single.$2, {
      'personality_id': 'coach',
      'findings': [
        {'text': 'f', 'kind': 'health'}
      ],
      'skill_pack_id': 'training',
    });
    expect((d.text, d.health, d.disclaimer), ('T', true, 'D'));
  });

  test('council v2: body and the relay result shape', () async {
    reply = {
      'synthesis': 'S. This is not medical advice.',
      'experts_consulted': ['sleep_lifestyle', 'cardiology'],
      'sources': [
        {'id': 'nhs-sleep-1', 'title': 'NHS: sleep hygiene', 'url': 'https://www.nhs.uk/x'},
        {'id': 'web:1', 'title': 'Web result', 'url': 'https://example.org', 'kind': 'web'},
        {'id': 'bad'},
      ],
      'medical': true,
      'purpose': 'chat',
      'providers': ['meta'],
      'consults': 2,
      'limits_hit': [],
      'advise_only': true,
    };
    final c = await port.council(
        question: 'q', context: const CouncilContext(shortTermSummary: 'synthetic summary'));
    expect(seen.single.$1, 'POST /council');
    expect(seen.single.$2, {
      'question': 'q',
      'context': {'short_term_summary': 'synthetic summary'},
      'purpose': 'chat',
    });
    expect(c.synthesis, 'S. This is not medical advice.');
    expect(c.expertsConsulted, ['sleep_lifestyle', 'cardiology']);
    expect(c.sources.map((s) => s.title), ['NHS: sleep hygiene', 'Web result']);
    expect(c.sources.last.kind, 'web');
    expect((c.medical, c.crisis, c.adviseOnly), (true, false, true));
  });

  test('council v2: no context sends none; an empty synthesis is invalid', () async {
    reply = {'synthesis': 'S'};
    await port.council(question: 'q', purpose: 'analysis');
    expect(seen.single.$2, {'question': 'q', 'purpose': 'analysis'});
    reply = {'synthesis': ''};
    await expectLater(port.council(question: 'q'),
        throwsA(isA<ServerException>().having((e) => e.error, 'error', 'invalid_response')));
  });

  test('digest carries the council view and the short-term context', () async {
    reply = {
      'text': 'T',
      'health': false,
      'disclaimer': null,
      'council': {'synthesis': 'C', 'experts_consulted': ['diet'], 'sources': [], 'medical': false},
      'council_code': null,
    };
    final d = await port.digest(
        personalityId: 'coach', findings: const [], context: const CouncilContext(shortTermSummary: 's'));
    expect(seen.single.$2['context'], {'short_term_summary': 's'});
    expect(seen.single.$2.containsKey('council'), isFalse);
    expect(d.council?.synthesis, 'C');
    reply = {'text': 'T', 'council': null, 'council_code': 'council_quota'};
    final e = await port.digest(personalityId: 'coach', findings: const [], council: false);
    expect(seen.last.$2['council'], false);
    expect((e.council, e.councilCode), (null, 'council_quota'));
  });

  test('error status becomes ServerException with the server code', () async {
    status = 503;
    reply = {'error': 'not_configured', 'detail': 'MEMORY_KEY missing'};
    await expectLater(
        port.route('x'),
        throwsA(isA<ServerException>()
            .having((e) => e.status, 'status', 503)
            .having((e) => e.error, 'error', 'not_configured')));
  });

  test('empty base url means the fake', () {
    final logs = <String>[];
    expect(serverPortFor('', deviceToken: token, log: logs.add), isA<FakeServerPort>());
    expect(serverPortFor('https://example.invalid', deviceToken: token, log: logs.add),
        isA<HttpServerPort>());
    expect(logs, isEmpty);
  });

  group('device token', () {
    test('every request carries the bearer token', () async {
      reply = {'text': 'T'};
      await port.route('x');
      await port.digest(personalityId: 'coach', findings: const []);
      await port.reply(plan: const {}, transcript: 'x');
      await port.turn(transcript: 'x');
      reply = {'text': 'T', 'synthesis': 'S'};
      await port.council(question: 'q');
      expect(seen.map((s) => s.$1),
          ['POST /router', 'POST /digest', 'POST /reply', 'POST /turn', 'POST /council']);
      expect(auth, List.filled(5, 'Bearer $token'));
    });

    test('no token: a URL falls back to the fake, logs one code, calls nothing', () async {
      for (final empty in ['', '   ']) {
        final logs = <String>[];
        final p = serverPortFor('http://127.0.0.1:${srv.port}', deviceToken: empty, log: logs.add);
        expect(p, isA<FakeServerPort>());
        expect(logs, ['server: no_device_token']);
        await p.route('x');
        await p.reply(plan: const {}, transcript: 'x');
      }
      expect(seen, isEmpty);
    });

    test('an HTTP port cannot be built with an empty or malformed token', () {
      for (final bad in ['', '   ', 'two words']) {
        expect(
            () => HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: bad),
            throwsA(isA<AssertionError>()
                .having((e) => '${e.message}', 'message', contains('non-empty device token'))));
      }
      // The assert message is fixed text, so a malformed token never shows.
      try {
        HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: 'two words');
        fail('expected an AssertionError');
      } on AssertionError catch (e) {
        expect('$e'.contains('two words'), isFalse);
      }
      expect(seen, isEmpty);
    });

    test('the token never appears in a log or an error', () async {
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        serverPortFor('http://127.0.0.1:${srv.port}', deviceToken: '');
        final p = serverPortFor('http://127.0.0.1:${srv.port}', deviceToken: token) as HttpServerPort;
        status = 401;
        reply = {'error': 'unauthorized'};
        final e = await p.route('x').then<Object?>((_) => null, onError: (Object e) => e);
        p.close();
        expect(e, isA<ServerException>().having((e) => e.status, 'status', 401));
        logs.add(e.toString());
        logs.add((e as ServerException).detail ?? '');
      } finally {
        debugPrint = saved;
      }
      expect(logs, contains('server: no_device_token'));
      for (final line in logs) {
        expect(line.contains(token), isFalse, reason: 'token leaked: $line');
        expect(line.contains('c3ludGhldGljLWhtYWM'), isFalse, reason: 'token leaked: $line');
      }
    });
  });

  test('knowledge add and remove use the Worker routes and shapes (server/src/spec/routes.js)', () async {
    reply = {'change_id': 'c1', 'base_version': 3, 'diff': [{'path': 'knowledge.add', 'from': null, 'to': 'reading'}], 'readback': 'R', 'expires_at': 1, 'via': 'app'};
    final p = await port.knowledgeAdd(baseVersion: 3, title: 'T', text: 'X', bank: 'sleep_lifestyle');
    expect(seen.last.$1, 'POST /knowledge/add');
    expect(seen.last.$2.keys, ['base_version', 'source']);
    final src = seen.last.$2['source'] as Map;
    expect((src['title'], src['text'], src['bank']), ('T', 'X', 'sleep_lifestyle'));
    expect(src['date'], matches(r'^\d{4}-\d{2}-\d{2}$'));
    expect((p.changeId, p.baseVersion, p.readback), ('c1', 3, 'R'));
    await port.knowledgeAdd(baseVersion: 3, title: 'T', text: 'X');
    expect((seen.last.$2['source'] as Map)['bank'], 'reading');
    await port.knowledgeRemove(baseVersion: 3, sourceId: 'src_0123456789abcdef');
    expect(seen.last.$1, 'POST /knowledge/remove');
    expect(seen.last.$2, {'base_version': 3, 'source_id': 'src_0123456789abcdef'});
    status = 422;
    reply = {'error': 'refused', 'code': 'refused', 'refused': [{'path': 'knowledge_add.bank', 'reason': 'unknown_bank'}]};
    await expectLater(port.knowledgeAdd(baseVersion: 3, title: 'T', text: 'X', bank: 'nope'),
        throwsA(isA<SpecRefused>().having((e) => e.refused, 'refused', [('knowledge_add.bank', 'unknown_bank')])));
  });
}
