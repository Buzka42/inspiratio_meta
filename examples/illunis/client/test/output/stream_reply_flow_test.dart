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

// Streamed replies (POST /reply/stream) through AppController. Synthetic
// fixtures only; marker words let the log check find leaks.
const transcript = 'zebra transcript about quokka plans';
const s1 = 'Walk for twenty minutes today.';
const s2 = 'Drink a glass of water after.';
const s3 = 'Then rest for a little while.';
const referral = 'Synthetic referral text. Please call a helpline.';

Future<void> settle([int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeServerPort server;
  late FakeTtsEngine engine;
  late AppController c;
  late List<TurnRequest> turns;
  late List<String> logs;
  late StreamController<ReplyStreamEvent> src;

  setUp(() {
    server = FakeServerPort(turnResult: const TurnPlan(personalityId: 'calm_guide', skillId: 'habit_building'));
    src = StreamController<ReplyStreamEvent>();
    server.replyStreamSource = src;
    engine = FakeTtsEngine(autoFinish: false);
    logs = [];
    c = AppController(
      fog: FogSettings(InMemoryKeyValueStore()),
      server: server,
      tts: SilentTts(),
      speech: SpeechOutput(engine, log: logs.add),
      log: logs.add,
    );
    turns = [];
    c.turnRequests.listen(turns.add);
  });

  Future<void> ask([String text = transcript]) {
    c.dispatch(const WakeWordHeard());
    c.dispatch(UserSpeechEnded(text));
    return c.routeTurn(turns.last);
  }

  List<String> plays() => [for (final t in engine.trace) if (t.startsWith('play:')) t.substring(5)];

  /// Lets every queued sentence finish.
  Future<void> drain() async {
    for (var i = 0; i < 10 && engine.isPlaying; i++) {
      engine.finishPlay();
      await settle();
    }
  }

  test('each sentence speaks as it arrives, in order, the next only after the last ends', () async {
    final done = ask();
    await settle();
    expect(server.calls, ['/turn', '/reply/stream']);
    expect(server.replyStreamCalls.single.plan, {'personality_id': 'calm_guide', 'skill_id': 'habit_building'});
    expect(server.replyStreamCalls.single.transcript, transcript);
    expect(c.voice, VoiceState.thinking);

    src.add(const ReplySentence(s1));
    await settle();
    expect(plays(), [s1], reason: 'spoken before the stream ends');
    expect(c.voice, VoiceState.speaking);
    expect(c.caption, s1);

    src.add(const ReplySentence(s2));
    await settle();
    expect(plays(), [s1], reason: 'the second waits for the first');

    engine.finishPlay();
    await settle();
    expect(plays(), [s1, s2]);
    expect(c.caption, s2);

    src.add(const ReplyStreamDone(text: s3, safety: 'passed'));
    await drain();
    await done;
    expect(engine.played, [s1, s2, s3]);
    expect(c.voice, VoiceState.idle);
    expect(logs, isEmpty);
    expect(server.calls, isNot(contains('/reply')));
  });

  test('done with safety "replaced" drops what has not started and speaks only the referral', () async {
    final done = ask();
    await settle();
    src
      ..add(const ReplySentence(s1))
      ..add(const ReplySentence(s2))
      ..add(const ReplyStreamDone(text: referral, safety: 'replaced'));
    await settle();
    expect(plays(), [s1]);
    await drain();
    await done;
    expect(engine.played, [s1, 'Synthetic referral text.', 'Please call a helpline.']);
    expect(engine.trace, isNot(contains('play:$s2')));
    expect(c.voice, VoiceState.idle);
  });

  test('an error event stops speech and speaks the fallback; code only in the log', () async {
    final done = ask();
    await settle();
    src
      ..add(const ReplySentence(s1))
      ..add(const ReplySentence(s2));
    await settle();
    src.add(const ReplyStreamError('reply_upstream'));
    await settle();
    expect(engine.stops, 1, reason: 'the current sentence is stopped');
    await drain();
    await done;
    expect(plays(), [s1, replyFallbackText]);
    expect(engine.played, [replyFallbackText]);
    expect(c.caption, replyFallbackText);
    expect(logs, ['reply: stream_failed code=reply_upstream']);
    expect(c.voice, VoiceState.idle);
  });

  test('a stream that drops before done falls back', () async {
    final done = ask();
    await settle();
    src.add(const ReplySentence(s1));
    await settle();
    await src.close();
    await settle();
    await drain();
    await done;
    expect(plays(), [s1, replyFallbackText]);
    expect(logs, ['reply: stream_failed code=stream_dropped']);
    expect(c.voice, VoiceState.idle);
  });

  test('a failed request before any event falls back', () async {
    server.replyStreamSource = null;
    server.replyStreamError = const ServerException(503, 'not_configured', 'quokka detail');
    engine.autoFinish = true;
    await ask();
    expect(engine.played, [replyFallbackText]);
    expect(logs, ['reply: stream_failed code=not_configured']);
    expect(server.calls, ['/turn', '/reply/stream']);
  });

  test('barge-in cancels the stream read and the queued speech at once', () async {
    final done = ask();
    await settle();
    src
      ..add(const ReplySentence(s1))
      ..add(const ReplySentence(s2));
    await settle();
    expect(plays(), [s1]);

    c.dispatch(const BargeIn());
    expect(server.replyStreamCancels, 1);
    expect(src.hasListener, isFalse, reason: 'the read is cancelled');
    expect(engine.stops, greaterThanOrEqualTo(1));
    await done;
    await settle();
    expect(plays(), [s1]);
    expect(engine.played, isEmpty);
    expect(c.voice, VoiceState.listening);
    expect(logs, isEmpty);
  });

  test('barge-in while waiting for the first sentence drops the turn', () async {
    final done = ask();
    await settle();
    c.dispatch(const BargeIn());
    expect(src.hasListener, isFalse);
    await done;
    expect(engine.trace, isEmpty);
    expect(c.voice, VoiceState.listening);
    expect(logs, isEmpty);
  });

  test('404 before any event (route not deployed) uses POST /reply', () async {
    server.replyStreamSource = null;
    server.replyStreamError = const ServerException(404, 'not_found');
    server.replyResult = const ReplyResult(text: s1);
    engine.autoFinish = true;
    await ask();
    expect(server.calls, ['/turn', '/reply/stream', '/reply']);
    expect(engine.played, [s1]);
    expect(logs, ['reply: stream_failed code=not_found']);
  });

  test('streamReplies: false keeps the /reply path', () async {
    final d = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: server,
        tts: SilentTts(),
        speech: SpeechOutput(FakeTtsEngine(), log: logs.add),
        log: logs.add,
        streamReplies: false);
    final t = <TurnRequest>[];
    d.turnRequests.listen(t.add);
    d.dispatch(const WakeWordHeard());
    d.dispatch(const UserSpeechEnded(transcript));
    await d.routeTurn(t.single);
    expect(server.calls, ['/turn', '/reply']);
    expect(server.replyStreamCalls, isEmpty);
  });

  test('no log line carries reply or transcript text', () async {
    engine.autoFinish = true;
    server.replyStreamSource = null;
    server.replyStreamEvents = [const ReplySentence(s1), const ReplyStreamError('reply_timeout')];
    await ask();
    server.replyStreamEvents = [const ReplySentence(s1)];
    await ask();
    server.replyStreamEvents = [const ReplyStreamError('Walk quokka $transcript')];
    await ask();
    server.replyStreamEvents = [const ReplyStreamDone(text: '')];
    await ask();
    server.replyStreamEvents = null;
    server.replyStreamError = StateError('$s1 $transcript');
    await ask();
    expect(logs, [
      'reply: stream_failed code=reply_timeout',
      'reply: stream_failed code=stream_dropped',
      'reply: stream_failed code=reply_error',
      'reply: stream_failed code=empty_reply',
      'reply: stream_failed code=reply_error',
    ]);
    for (final line in logs) {
      for (final word in ['zebra', 'quokka', 'Walk', 'water', 'referral']) {
        expect(line.contains(word), isFalse, reason: 'log leaked text: $line');
      }
    }
  });

  group('over loopback HTTP', () {
    late HttpServer srv;
    late HttpServerPort port;
    final paths = <String>[];

    setUp(() async {
      paths.clear();
      srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((req) async {
        await utf8.decoder.bind(req).join();
        paths.add(req.uri.path);
        final res = req.response;
        if (req.uri.path == '/turn') {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'crisis': false, 'personality_id': 'calm_guide', 'skill_id': null}));
          return res.close();
        }
        res.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
        res.bufferOutput = false;
        for (final p in [
          'event: sentence\ndata: {"text":"$s1"}\n\n',
          'event: sentence\ndata: {"text":"$s2"}\n\nevent: do',
          'ne\ndata: {"text":"$s3","personality_id":"calm_guide","safety":"passed","health":false}',
        ]) {
          res.write(p);
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await res.close();
      });
      port = HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: 'test-only-fake-device-token');
    });

    tearDown(() async {
      port.close();
      await srv.close(force: true);
    });

    test('a voice turn is POST /turn, then POST /reply/stream; every sentence spoken', () async {
      final e = FakeTtsEngine();
      final d = AppController(
          fog: FogSettings(InMemoryKeyValueStore()),
          server: port,
          tts: SilentTts(),
          speech: SpeechOutput(e, log: logs.add),
          log: logs.add);
      final t = <TurnRequest>[];
      d.turnRequests.listen(t.add);
      d.dispatch(const WakeWordHeard());
      d.dispatch(const UserSpeechEnded('plan my morning'));
      await d.routeTurn(t.single);
      expect(paths, ['/turn', '/reply/stream']);
      expect(e.played, [s1, s2, s3]);
      expect(d.voice, VoiceState.idle);
      expect(logs, isEmpty);
    });
  });
}
