// Typed onboarding (voice off): the greeting shows once in the chat, also
// when the app starts again before the first answer (activity recreated,
// process killed, a second launch). The thread is restored from the store
// and already ends with the greeting, so it must not be added again (it
// used to merge into the same bubble: the greeting twice, back to back).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_settings.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/voice_setup.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/thread_engine.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/widgets/chat_composer.dart';

final _greeting = const InterviewState().promptFor(typed: true);

/// One app launch as main.dart wires it with voice off.
Future<ChatThread> _launch(StateStore store) async {
  final thread = ChatThread(store: store);
  await thread.load();
  final speech = SpeechOutput(ThreadEngine(thread.addAssistant), log: (_) {});
  final flow = MorningFlow(tts: SpeechOutputTts(speech), server: FakeServerPort(), store: store, speech: speech);
  await flow.load();
  final setup = VoiceSetup(
    flow: flow,
    alarmStore: AlarmSettingsStore(store),
    typed: true,
    shownLast: thread.endsWithAssistant,
    log: (_) {},
  );
  await setup.load();
  await setup.start();
  await thread.saved;
  return thread;
}

int _count(String haystack, String needle) => needle.allMatches(haystack).length;

String _shownText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join('\n');

Future<void> _pump(WidgetTester t, ChatThread thread) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: ChatComposer(thread: thread, onSubmit: (_) {}))));
  await t.pump();
}

void main() {
  testWidgets('first launch shows the greeting exactly once', (t) async {
    final thread = (await t.runAsync(() => _launch(InMemoryStateStore())))!;
    await _pump(t, thread);
    expect(_count(_shownText(t), _greeting), 1);
    expect(thread.entries, hasLength(1));
  });

  testWidgets('a second launch before any answer does not repeat the greeting', (t) async {
    final store = InMemoryStateStore();
    await t.runAsync(() => _launch(store));
    final thread = (await t.runAsync(() => _launch(store)))!;
    await _pump(t, thread);
    expect(_count(_shownText(t), _greeting), 1);
    expect(_count(thread.entries.single.text, _greeting), 1);
  });

  testWidgets('a restart after an answer asks the current question again', (t) async {
    // The thread ends with the user's answer, not the next prompt: it is shown.
    final store = InMemoryStateStore();
    final first = (await t.runAsync(() => _launch(store)))!;
    first.addUser('Hi');
    await t.runAsync(() => first.saved);
    final thread = (await t.runAsync(() => _launch(store)))!;
    expect(thread.entries.last.role, ChatRole.assistant);
    expect(thread.entries.last.text, _greeting);
    expect(thread.entries, hasLength(3));
  });
}
