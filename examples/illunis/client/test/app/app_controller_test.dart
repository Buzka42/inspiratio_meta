import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/core/mode_controller.dart';
import 'package:illunis_client/voice/voice_session.dart';

// Synthetic fixtures only.
const referral = 'Fixed referral text.';

void main() {
  late FakeServerPort server;
  late SilentTts tts;
  late AppController c;
  late List<TurnRequest> turns;

  setUp(() {
    server = FakeServerPort();
    tts = SilentTts();
    c = AppController(fog: FogSettings(InMemoryKeyValueStore()), server: server, tts: tts);
    turns = [];
    c.turnRequests.listen(turns.add);
  });

  test('mode command switches mode and emits no turn', () {
    expect(c.mode, GraphicMode.reflection);
    expect(c.handleUtterance('Show me the sky.'), UtteranceOutcome.modeChanged);
    expect(c.mode, GraphicMode.classic);
    expect(turns, isEmpty);
    expect(server.calls, isEmpty);
  });

  test('other speech emits a turn request with rising ids', () {
    expect(c.handleUtterance('plan my day'), UtteranceOutcome.turnRequested);
    expect(c.handleUtterance('and tomorrow'), UtteranceOutcome.turnRequested);
    expect(turns.map((t) => t.text), ['plan my day', 'and tomorrow']);
    expect(turns[1].id, greaterThan(turns[0].id));
    expect(c.handleUtterance('   '), UtteranceOutcome.ignored);
  });

  test('voice transcript that is a mode command returns to idle', () {
    c.dispatch(const WakeWordHeard());
    expect(c.voice, VoiceState.listening);
    c.dispatch(const UserSpeechEnded('show the water'));
    expect(c.voice, VoiceState.idle);
    expect(turns, isEmpty);
  });

  test('voice transcript becomes a routed turn', () async {
    c.dispatch(const WakeWordHeard());
    c.dispatch(const UserSpeechEnded('plan my day'));
    expect(c.voice, VoiceState.thinking);
    expect(turns.single.text, 'plan my day');
    server.turnResult = const TurnPlan(personalityId: 'advisor', skillId: 'productivity');
    await c.routeTurn(turns.single);
    expect(server.calls, ['/turn', '/reply/stream']); // Streaming is the default.
    expect(server.turnCalls.single.transcript, 'plan my day');
    expect(server.replyStreamCalls.single.plan,
        {'personality_id': 'advisor', 'skill_id': 'productivity'});
    expect(c.lastPlan?.skillId, 'productivity');
    expect(c.voice, VoiceState.idle);
    expect(tts.spoken, ['Synthetic reply.']); // FakeServerPort's default reply.
  });

  test('crisis from /turn speaks the fixed referral and shows it as caption', () async {
    server.turnResult = const TurnPlan(crisis: true, escalate: true, response: referral);
    c.dispatch(const WakeWordHeard());
    c.dispatch(const UserSpeechEnded('synthetic crisis phrase'));
    await c.routeTurn(turns.single);
    expect(tts.spoken, [referral]);
    expect(c.caption, referral);
    expect(server.calls, ['/turn']);
    expect(c.voice, VoiceState.idle);
  });

  test('barge-in stops playback and drops the cancelled reply', () async {
    server.turnResult = const TurnPlan(crisis: true, response: referral);
    c.dispatch(const WakeWordHeard());
    c.dispatch(const UserSpeechEnded('first'));
    c.dispatch(const BargeIn()); // while thinking: cancel generation
    expect(c.voice, VoiceState.listening);
    await c.routeTurn(turns.single);
    expect(tts.spoken, isEmpty);

    c.dispatch(const UserSpeechEnded('second'));
    c.dispatch(const ReplyChunk('Hello.'));
    expect(c.voice, VoiceState.speaking);
    c.dispatch(const UserSpeechStarted());
    expect(tts.stops, 1);
    expect(c.voice, VoiceState.listening);
  });

  test('fog setting persists through the store', () async {
    final store = InMemoryKeyValueStore();
    final a = AppController(fog: FogSettings(store), server: server, tts: tts);
    await a.load();
    expect(a.fogEnabled, isTrue);
    await a.setFog(false);
    final b = AppController(fog: FogSettings(store), server: server, tts: tts);
    await b.load();
    expect(b.fogEnabled, isFalse);
  });

  test('listeners fire on mode change', () {
    var n = 0;
    c.addListener(() => n++);
    c.handleUtterance('show me the sky');
    expect(n, 1);
  });
}
