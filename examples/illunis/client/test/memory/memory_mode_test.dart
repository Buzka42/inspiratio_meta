import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/memory/assistant_memory_backend.dart';
import 'package:illunis_client/memory/local_memory_backend.dart';
import 'package:illunis_client/memory/memory_mode.dart';
import 'package:illunis_client/memory/memory_note.dart';

// Memory mode chosen by voice. Synthetic data only.

void main() {
  group('parseMemoryModeIntent', () {
    test('reads the spoken settings', () {
      expect(parseMemoryModeIntent('Use my assistant for memory.'), MemoryMode.assistant);
      expect(parseMemoryModeIntent('keep memory on the phone'), MemoryMode.phone);
      expect(parseMemoryModeIntent('please store my memories locally'), MemoryMode.phone);
      expect(parseMemoryModeIntent('switch memory to Hermes'), MemoryMode.assistant);
      expect(parseMemoryModeIntent('move my memory to my server'), MemoryMode.vps);
    });

    test('ignores questions, other talk and mixed places', () {
      expect(parseMemoryModeIntent('where do you keep memory on my phone?'), isNull);
      expect(parseMemoryModeIntent('what is in your memory'), isNull);
      expect(parseMemoryModeIntent('use my phone alarm'), isNull); // No memory word.
      expect(parseMemoryModeIntent('memory phone'), isNull); // No verb.
      expect(parseMemoryModeIntent('keep memory on the phone and the assistant'), isNull);
    });

    test('answers to the question need only the place', () {
      expect(parseMemoryModeAnswer('the phone'), MemoryMode.phone);
      expect(parseMemoryModeAnswer('my assistant please'), MemoryMode.assistant);
      expect(parseMemoryModeAnswer('hmm'), isNull);
    });

    test('a stored vps or junk choice decodes to the phone', () {
      expect(MemoryModeChoice.decode('{"mode":"vps","chosen":true}').mode, MemoryMode.phone);
      expect(MemoryModeChoice.decode('nope').chosen, isFalse);
      expect(MemoryModeChoice.decode(const MemoryModeChoice(mode: MemoryMode.assistant, chosen: true).encode()).mode,
          MemoryMode.assistant);
    });
  });

  group('SelectedMemoryBackend', () {
    test('writes and recalls through the current mode', () async {
      final server = FakeServerPort();
      final phone = LocalMemoryBackend(InMemoryStateStore());
      final b = SelectedMemoryBackend(phone: phone, assistant: AssistantMemoryBackend(server));
      const n = MemoryNote(text: 'zebra note', label: MemoryLabel.note, confidence: 0.8);
      await b.write(n);
      expect(b.id, 'phone');
      expect(server.assistantWrites, isEmpty);
      b.mode = MemoryMode.assistant;
      await b.write(n);
      expect(server.assistantWrites, hasLength(1));
      b.mode = MemoryMode.vps;
      await expectLater(b.write(n), throwsA(anything));
    });
  });

  group('MemoryModeSetup', () {
    late InMemoryStateStore store;
    late SelectedMemoryBackend backend;
    late List<String> spoken;
    late List<String> logs;
    late int listens;
    late bool assistantLinked;

    MemoryModeSetup build({bool ready = true}) => MemoryModeSetup(
          store: store,
          backend: backend,
          speak: (t) async => spoken.add(t),
          listen: () => listens++,
          ready: () => ready,
          assistantAvailable: () => assistantLinked,
          log: logs.add,
        );

    setUp(() {
      store = InMemoryStateStore();
      backend = SelectedMemoryBackend(
          phone: LocalMemoryBackend(InMemoryStateStore()), assistant: AssistantMemoryBackend(FakeServerPort()));
      spoken = [];
      logs = [];
      listens = 0;
      assistantLinked = true;
    });

    test('asks once, takes the answer, and persists it', () async {
      final s = build();
      await s.offer();
      expect(spoken.single, MemoryModePrompt.offer);
      expect(listens, 1);
      expect(s.claim('hmm'), isTrue);
      await s.settled;
      expect(spoken.last, MemoryModePrompt.reask);
      expect(s.claim('my assistant'), isTrue);
      await s.settled;
      expect(spoken.last, MemoryModePrompt.assistant);
      expect(backend.mode, MemoryMode.assistant);
      await s.offer(); // Answered: not asked again.
      expect(spoken.where((t) => t == MemoryModePrompt.offer), hasLength(1));

      final again = build();
      await again.load();
      expect((again.mode, again.chosen), (MemoryMode.assistant, true));
      expect(await store.getString(StoreKeys.memoryMode), contains('assistant'));
    });

    test('the intent works any time after setup; other talk is not claimed', () async {
      final s = build();
      expect(s.claim('what is the weather'), isFalse);
      expect(s.claim('keep memory on the phone'), isTrue);
      await s.settled;
      expect(spoken.single, MemoryModePrompt.phone);
      expect(backend.mode, MemoryMode.phone);
    });

    test('the VPS is refused and memory stays on the phone', () async {
      final s = build();
      s.claim('store my memory on my server');
      await s.settled;
      expect(spoken.single, MemoryModePrompt.vps);
      expect(backend.mode, MemoryMode.phone);
    });

    test('without an assistant link the phone is used', () async {
      assistantLinked = false;
      final s = build();
      s.claim('use my assistant for memory');
      await s.settled;
      expect(spoken.single, MemoryModePrompt.noAssistant);
      expect(backend.mode, MemoryMode.phone);
    });

    test('not ready: neither offered nor claimed; logs never carry the transcript', () async {
      final s = build(ready: false);
      await s.offer();
      expect(s.claim('use my assistant for memory'), isFalse);
      expect(spoken, isEmpty);
      final t = build();
      await t.offer();
      t.claim('zebra quokka');
      await t.settled;
      expect(logs.join(' '), isNot(contains('zebra')));
    });
  });
}
