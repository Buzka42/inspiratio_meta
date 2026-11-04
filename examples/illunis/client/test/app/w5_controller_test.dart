import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/voice/voice_session.dart';

// AppController seams for the voice flows. Synthetic only.
void main() {
  late FakeServerPort server;
  late FakeTtsEngine engine;
  late AppController c;
  late List<TurnRequest> turns;
  late List<AnsweredTurn> answered;

  setUp(() {
    server = FakeServerPort();
    engine = FakeTtsEngine();
    c = AppController(
      fog: FogSettings(InMemoryKeyValueStore()),
      server: server,
      tts: SilentTts(),
      speech: SpeechOutput(engine, log: (_) {}),
      log: (_) {},
    );
    turns = [];
    answered = [];
    c.turnRequests.listen(turns.add);
    c.afterAnswer = answered.add;
  });

  Future<void> ask(String text) {
    c.dispatch(const WakeWordHeard());
    c.dispatch(UserSpeechEnded(text));
    return c.routeTurn(turns.last);
  }

  test('afterAnswer gets the transcript, the answer and the stream flag', () async {
    server.replyStreamEvents = const [
      ReplySentence('Synthetic one.'),
      ReplyStreamDone(text: 'Synthetic two.', safety: 'passed', councilSuggested: true),
    ];
    await ask('synthetic question');
    expect(answered.single.transcript, 'synthetic question');
    expect(answered.single.answer, 'Synthetic one. Synthetic two.');
    expect(answered.single.councilSuggested, isTrue);
    expect(c.idle, isTrue);
  });

  test('the /reply path carries the flag too; none means false', () async {
    final d = AppController(
      fog: FogSettings(InMemoryKeyValueStore()),
      server: server,
      tts: SilentTts(),
      speech: SpeechOutput(engine, log: (_) {}),
      streamReplies: false,
      log: (_) {},
    );
    final got = <AnsweredTurn>[];
    final reqs = <TurnRequest>[];
    d.turnRequests.listen(reqs.add);
    d.afterAnswer = got.add;
    server.replyResult = const ReplyResult(text: 'Synthetic.', councilSuggested: true);
    d.handleUtterance('q');
    await d.routeTurn(reqs.last);
    server.replyResult = const ReplyResult(text: 'Synthetic.');
    d.handleUtterance('q');
    await d.routeTurn(reqs.last);
    expect(got.map((a) => a.councilSuggested), [true, false]);
  });

  test('no afterAnswer on a fallback or a replaced reply', () async {
    server.replyStreamError = const ServerException(502, 'upstream_error');
    await ask('q');
    server.replyStreamError = null;
    server.replyStreamEvents = const [ReplyStreamDone(text: 'Synthetic referral.', safety: 'replaced')];
    await ask('q');
    expect(answered, isEmpty);
  });

  test('speakAside speaks through the shared queue and captions each sentence', () async {
    expect(await c.speakAside('Synthetic first. Synthetic second.'), isTrue);
    expect(engine.played, ['Synthetic first.', 'Synthetic second.']);
    expect(c.caption, 'Synthetic second.');
    c.showCaption('Sources: A');
    expect(c.caption, 'Sources: A');
  });

  test('a wake word cancels aside speech like the digest', () async {
    engine.autoFinish = false;
    final f = c.speakAside('Synthetic aside.');
    await Future<void>.delayed(Duration.zero);
    expect(c.idle, isFalse);
    c.dispatch(const WakeWordHeard());
    expect(await f, isFalse);
    expect(c.voice, VoiceState.listening);
  });
}
