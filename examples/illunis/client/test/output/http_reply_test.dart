import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Synthetic /turn answer, shaped like server/src/turn.js runTurn.
const turnJson = {
  'crisis': false,
  'personality_id': 'calm_guide',
  'skill_id': 'habit_building',
  'system_prompt': 'synthetic server prompt',
  'memories': [
    {'id': 'm1', 'text': 'synthetic memory', 'label': 'fact'},
  ],
  'escalate': false,
};

// Loopback server shaped like the POST /turn and /reply contracts.
// Synthetic data only.
void main() {
  late HttpServer srv;
  late HttpServerPort port;
  final seen = <(String, Map<String, dynamic>)>[];
  final auth = <String?>[];
  // Fake value for loopback tests only; not a real device token.
  const testToken = 'test-only-fake-device-token';
  Completer<void>? hold;

  setUp(() async {
    seen.clear();
    auth.clear();
    hold = null;
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      seen.add(('${req.method} ${req.uri.path}', body));
      auth.add(req.headers.value(HttpHeaders.authorizationHeader));
      await hold?.future;
      final answer = req.uri.path == '/turn'
          ? turnJson
          : {'text': 'T.', 'personality_id': 'calm_guide', 'safety': {'ok': true}};
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer));
      await req.response.close();
    });
    port = HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: testToken);
  });

  tearDown(() async {
    port.close();
    await srv.close(force: true);
  });

  test('reply posts {plan, transcript} and parses the result', () async {
    final r = await port.reply(plan: const {'personality_id': 'calm_guide'}, transcript: 'hi');
    expect(seen.single.$1, 'POST /reply');
    expect(seen.single.$2, {
      'plan': {'personality_id': 'calm_guide'},
      'transcript': 'hi',
    });
    expect((r.text, r.personalityId), ('T.', 'calm_guide'));
    expect(r.safety, {'ok': true});
  });

  test('a cancelled token aborts the request with code cancelled', () async {
    hold = Completer<void>();
    final token = CancelToken();
    final f = port.reply(plan: const {}, transcript: 'hi', cancel: token);
    while (seen.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    token.cancel();
    await expectLater(
        f, throwsA(isA<ServerException>().having((e) => e.error, 'error', 'cancelled')));
    hold!.complete();
  });

  test('turn posts {transcript, context} and parses the plan', () async {
    final p = await port.turn(transcript: 'hi', context: const {'query': 'q'});
    expect(seen.single.$1, 'POST /turn');
    expect(seen.single.$2, {
      'transcript': 'hi',
      'context': {'query': 'q'},
    });
    expect((p.crisis, p.personalityId, p.skillId), (false, 'calm_guide', 'habit_building'));
  });

  test('the reply plan carries ids only, never server prompt or memories', () {
    final p = TurnPlan.fromJson(turnJson);
    expect(p.toReplyPlan(), {'personality_id': 'calm_guide', 'skill_id': 'habit_building'});
  });

  test('a cancelled token aborts /turn with code cancelled', () async {
    hold = Completer<void>();
    final token = CancelToken();
    final f = port.turn(transcript: 'hi', cancel: token);
    while (seen.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    token.cancel();
    await expectLater(
        f, throwsA(isA<ServerException>().having((e) => e.error, 'error', 'cancelled')));
    hold!.complete();
  });

  test('a voice turn on the wire is POST /turn, then POST /reply with that plan', () async {
    final engine = FakeTtsEngine();
    final c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: port,
        tts: SilentTts(),
        speech: SpeechOutput(engine, log: (_) {}),
        log: (_) {},
        streamReplies: false);
    final turns = <TurnRequest>[];
    c.turnRequests.listen(turns.add);
    c.dispatch(const WakeWordHeard());
    c.dispatch(const UserSpeechEnded('plan my morning'));
    await c.routeTurn(turns.single);

    expect(seen.map((s) => s.$1), ['POST /turn', 'POST /reply']);
    expect(seen[0].$2, {'transcript': 'plan my morning', 'context': <String, dynamic>{}});
    expect(seen[1].$2, {
      'plan': {'personality_id': 'calm_guide', 'skill_id': 'habit_building'},
      'transcript': 'plan my morning',
    });
    expect(auth, ['Bearer $testToken', 'Bearer $testToken']);
    expect(engine.played, ['T.']);
    expect(c.voice, VoiceState.idle);
  });
}
