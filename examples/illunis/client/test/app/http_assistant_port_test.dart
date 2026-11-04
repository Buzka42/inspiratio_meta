import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/server_port.dart';

// Loopback server for the council and assistant routes: bodies and answers shaped like
// server/src/assistants/routes.js and analysis/run21d.js. Synthetic only.
void main() {
  late HttpServer srv;
  late HttpServerPort port;
  final seen = <(String, Object?)>[];
  const token = 'synthetic-device.c3ludGhldGljLWhtYWM';
  var status = 200;
  Object reply = {};

  setUp(() async {
    seen.clear();
    status = 200;
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      seen.add(('${req.method} ${req.uri}', raw.isEmpty ? null : jsonDecode(raw)));
      expect(req.headers.value(HttpHeaders.authorizationHeader), 'Bearer $token');
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply));
      await req.response.close();
    });
    port = HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: token);
  });

  tearDown(() async {
    port.close();
    await srv.close(force: true);
  });

  test('analysis21d posts the body and reads comment, notice and council meta', () async {
    reply = {
      'window': {'days': 21},
      'findings': [],
      'comment': 'Synthetic comment.',
      'comment_code': null,
      'notice': 'Synthetic notice.',
      'council': {
        'experts_consulted': ['sleep_lifestyle'],
        'sources': [
          {'id': 'n1', 'title': 'NHS: sleep', 'url': 'https://www.nhs.uk/x'}
        ],
        'medical': false,
      },
    };
    final body = {'checkins': [], 'signals': [], 'tz': 'UTC'};
    final r = await port.analysis21d(body);
    expect(seen.single.$1, 'POST /analysis/21d');
    expect(seen.single.$2, body);
    expect((r.comment, r.notice, r.crisis), ('Synthetic comment.', 'Synthetic notice.', false));
    expect(r.sources.single.title, 'NHS: sleep');
    reply = {'crisis': true, 'text': 'Synthetic referral.'};
    final c = await port.analysis21d(body);
    expect((c.crisis, c.text, c.comment), (true, 'Synthetic referral.', null));
  });

  test('assistantMessage: {text, context}; reply text, safety, optional proposal', () async {
    reply = {'text': 'Synthetic answer.', 'safety': 'passed', 'health': false};
    final r = await port.assistantMessage('q', context: 'User: synthetic');
    expect(seen.single.$1, 'POST /assistant/message');
    expect(seen.single.$2, {'text': 'q', 'context': 'User: synthetic'});
    expect((r.text, r.safety, r.proposal), ('Synthetic answer.', 'passed', null));
    await port.assistantMessage('q');
    expect(seen.last.$2, {'text': 'q'});
  });

  test('assistantPropose: {request} -> {action_id, readback, expires_in}', () async {
    reply = {'action_id': 'act_${'a' * 32}', 'readback': 'I will message b: hi', 'expires_in': 60};
    final p = await port.assistantPropose('message b hi');
    expect(seen.single.$1, 'POST /assistant/action/propose');
    expect(seen.single.$2, {'request': 'message b hi'});
    expect((p.actionId, p.readback, p.expiresIn), ('act_${'a' * 32}', 'I will message b: hi', 60));
  });

  test('assistantPropose: a malformed id is invalid; 422 crisis becomes ActionRefused', () async {
    reply = {'action_id': 'nope', 'readback': 'x'};
    await expectLater(port.assistantPropose('r'),
        throwsA(isA<ServerException>().having((e) => e.error, 'error', 'invalid_response')));
    status = 422;
    reply = {'error': 'action_refused', 'code': 'crisis', 'text': 'Synthetic referral.'};
    await expectLater(
        port.assistantPropose('r'),
        throwsA(isA<ActionRefused>()
            .having((e) => e.code, 'code', 'crisis')
            .having((e) => e.referral, 'referral', 'Synthetic referral.')));
  });

  test('assistantConfirm sends exactly {action_id, confirm_phrase_heard: true}', () async {
    reply = {'action_id': 'act_${'b' * 32}', 'status': 'done'};
    final o = await port.assistantConfirm('act_${'b' * 32}');
    expect(seen.single.$1, 'POST /assistant/action/confirm');
    expect(seen.single.$2, {'action_id': 'act_${'b' * 32}', 'confirm_phrase_heard': true});
    expect(o.status, 'done');
  });

  test('assistantConfirm 410 and 404 fail with their status', () async {
    for (final (s, e) in [(410, 'action_expired'), (404, 'action_unknown')]) {
      status = s;
      reply = {'error': e};
      await expectLater(port.assistantConfirm('act_${'c' * 32}'),
          throwsA(isA<ServerException>().having((x) => x.status, 'status', s).having((x) => x.error, 'error', e)));
    }
  });

  test('assistantInbox is a GET with no body; malformed items are dropped', () async {
    reply = {
      'items': [
        {'id': 'i1', 'kind': 'message', 'text': 'Synthetic.', 'ts': 1700000000},
        {'id': 'i2', 'kind': 'message', 'text': '', 'ts': 1},
        {'kind': 'message', 'text': 'x', 'ts': 1},
      ],
      'more': true,
    };
    final b = await port.assistantInbox();
    expect(seen.single.$1, 'GET /assistant/inbox?limit=20');
    expect(seen.single.$2, null);
    expect(b.items.map((i) => i.id), ['i1']);
    expect(b.more, isTrue);
  });

  test('error bodies keep the sub-code', () async {
    status = 502;
    reply = {'error': 'assistant_unavailable', 'code': 'hermes_contract'};
    await expectLater(
        port.assistantMessage('q'),
        throwsA(isA<ServerException>()
            .having((e) => e.error, 'error', 'assistant_unavailable')
            .having((e) => e.code, 'code', 'hermes_contract')));
  });
}
