// A "repaired" safety value is a normal answer: it is spoken, and it writes
// memory exactly as "passed" does, on /reply and on the stream. Synthetic data.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/memory_writer.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/memory/memory_backend.dart';
import 'package:illunis_client/memory/memory_note.dart';
import 'package:illunis_client/voice/voice_session.dart';

const statement = 'I sleep badly after zebra quokka evenings';
const answer = 'Try oats with fruit. Add some yoghurt if you like.';
final now = DateTime.utc(2026, 10, 25, 9);

class _Backend implements MemoryBackend {
  final writes = <MemoryNote>[];
  @override
  String get id => 'phone';
  @override
  Future<void> write(MemoryNote note) async => writes.add(note);
  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) async => const [];
  @override
  Future<MemorySummary> summary() async => MemorySummary(backend: id, noteCount: writes.length);
}

void main() {
  test('a repaired stream done is not replaced', () {
    final e = ReplyStreamEvent.fromSse(const SseEvent('done', '{"text":"A.","safety":"repaired"}'));
    final d = e as ReplyStreamDone;
    expect((d.text, d.safety, d.replaced), ('A.', 'repaired', false));
  });

  group('repaired reply', () {
    late FakeServerPort server;
    late _Backend backend;
    late SilentTts tts;
    late List<TurnRequest> turns;

    AppController build({required bool stream}) {
      final ctl = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: server,
        tts: tts,
        log: (_) {},
        streamReplies: stream,
        memory: MemoryWriter(backend, log: (_) {}, clock: () => now),
      );
      ctl.turnRequests.listen(turns.add);
      return ctl;
    }

    setUp(() {
      server = FakeServerPort(replyResult: const ReplyResult(text: answer, safety: 'repaired'));
      backend = _Backend();
      tts = SilentTts();
      turns = [];
    });

    Future<void> ask(AppController c, String text) async {
      c.dispatch(const WakeWordHeard());
      c.dispatch(UserSpeechEnded(text));
      await c.routeTurn(turns.last);
      await Future<void>.delayed(Duration.zero);
    }

    test('on the stream it is spoken and stores the same note as passed', () async {
      server.replyStreamEvents = [const ReplyStreamDone(text: answer, safety: 'repaired')];
      await ask(build(stream: true), statement);
      expect(tts.spoken.join(' '), answer);
      expect(backend.writes.single.text, 'User said: $statement');
    });

    test('on /reply it is spoken and stores a note', () async {
      await ask(build(stream: false), statement);
      expect(tts.spoken.join(' '), answer);
      expect(backend.writes, hasLength(1));
    });
  });
}
