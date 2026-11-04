// Typed chat thread: bubbles, merging, sources, persistence, and a typed
// turn end to end through AppController with no audio. Synthetic text only.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/core/voice_flags.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/thread_engine.dart';
import 'package:illunis_client/voice/voice_session.dart';

({AppController c, ChatThread thread, FakeServerPort server, FakeTtsEngine audio}) rig() {
  final thread = ChatThread(store: InMemoryStateStore());
  final audio = FakeTtsEngine();
  // As main.dart: the audio engine only when voice is on.
  final speech = SpeechOutput(voiceEnabled ? audio : ThreadEngine(thread.addAssistant), log: (_) {});
  final server = FakeServerPort();
  final c = AppController(
      fog: FogSettings(InMemoryKeyValueStore()),
      server: server,
      tts: SpeechOutputTts(speech),
      speech: speech,
      log: (_) {});
  c.turnRequests.listen(c.routeTurn);
  return (c: c, thread: thread, server: server, audio: audio);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('voice is off by default', () => expect(voiceEnabled, isFalse));

  test('a typed turn from idle gives a user and an assistant bubble, no audio', () async {
    final r = rig();
    r.server.replyStreamEvents = const [
      ReplySentence('First synthetic sentence.'),
      ReplySentence('Second synthetic sentence.'),
      ReplyStreamDone(text: ''),
    ];
    expect(r.c.voice, VoiceState.idle);
    submitTypedTurn(r.c, r.thread, '  plan my day  ');
    await settle();

    final e = r.thread.entries;
    expect(e.map((x) => x.role), [ChatRole.user, ChatRole.assistant]);
    expect(e[0].text, 'plan my day');
    // Consecutive sentences merge into one bubble.
    expect(e[1].text, 'First synthetic sentence. Second synthetic sentence.');
    expect(r.server.turnCalls.single.transcript, 'plan my day');
    expect(r.audio.played, isEmpty);
    expect(r.audio.trace, isEmpty);
    expect(r.c.voice, VoiceState.idle);
    expect(r.c.idle, isTrue);
  });

  test('the non-streamed /reply route also fills the thread', () async {
    final r = rig();
    r.server.replyStreamError = const ServerException(404, 'not_found');
    submitTypedTurn(r.c, r.thread, 'hello');
    await settle();
    expect(r.thread.entries.last.text, 'Synthetic reply.');
    expect(r.server.calls, contains('/reply'));
  });

  test('a typed turn claimed by setupHook ends the turn without a server call', () async {
    final r = rig();
    r.c.setupHook = (t) => t == 'yes';
    submitTypedTurn(r.c, r.thread, 'yes');
    await settle();
    expect(r.server.turnCalls, isEmpty);
    expect(r.c.voice, VoiceState.idle);
  });

  test('a typed turn while a reply is pending replaces it', () async {
    final r = rig();
    r.server.turnGate = Completer<void>();
    submitTypedTurn(r.c, r.thread, 'first');
    await settle();
    expect(r.c.voice, VoiceState.thinking);
    submitTypedTurn(r.c, r.thread, 'second');
    r.server.turnGate!.complete();
    await settle();
    expect(r.server.turnCancels, 1);
    expect(r.thread.entries.where((e) => e.role == ChatRole.assistant).length, 1);
    expect(r.c.voice, VoiceState.idle);
  });

  test('council sources attach to the answer bubble and close it', () {
    final t = ChatThread();
    t.addAssistant('Council answer.');
    t.attachSources('Sources: A · B');
    t.addAssistant('Next.');
    expect(t.entries.length, 2);
    expect(t.entries[0].sources, 'Sources: A · B');
    expect(t.entries[1].text, 'Next.');
  });

  test('offers are their own bubble; a new user message closes an open one', () {
    final t = ChatThread();
    t.addAssistant('Reply.');
    t.addOffer('Open your logs?', 'view-1');
    expect(t.entries.length, 2);
    expect(t.entries.last.offer!.isOpen, isTrue);
    t.addUser('something else');
    expect(t.entries[1].offer!.state, OfferState.closed);
    t.closeOffer('view-1', OfferState.accepted);
    expect(t.entries[1].offer!.state, OfferState.accepted);
    expect(t.latestExchange.single.text, 'something else');
  });

  test('persists under chat_thread; open offers do not survive a restart', () async {
    final store = InMemoryStateStore();
    final t = ChatThread(store: store)
      ..addUser('Synthetic question.')
      ..addAssistant('Synthetic answer.')
      ..addOffer('Open breathwork?', 'view-1');
    await t.saved;
    expect(await store.getString(StoreKeys.chatThread), isNotNull);

    final back = ChatThread(store: store);
    await back.load();
    expect(back.entries.map((e) => e.text), ['Synthetic question.', 'Synthetic answer.', 'Open breathwork?']);
    expect(back.entries.last.offer!.state, OfferState.closed);
  });

  test('a corrupt store gives an empty thread; old entries are capped', () async {
    final store = InMemoryStateStore();
    await store.setString(StoreKeys.chatThread, '{not json');
    final t = ChatThread(store: store, maxEntries: 3);
    await t.load();
    expect(t.entries, isEmpty);
    for (var i = 0; i < 5; i++) {
      t.addUser('m$i');
    }
    expect(t.entries.map((e) => e.text), ['m2', 'm3', 'm4']);
  });
}
