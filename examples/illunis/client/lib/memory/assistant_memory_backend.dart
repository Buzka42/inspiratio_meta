/// Long-term memory kept by the connected assistant (Hermes `illunis`
/// profile), reached through the Worker: POST /assistant/memory/write and
/// POST /assistant/memory/recall (server/src/assistants/). The phone
/// keeps no copy; recall asks the assistant each time.
library;

import '../app/server_port.dart';
import 'memory_backend.dart';
import 'memory_note.dart';

class AssistantMemoryBackend implements MemoryBackend {
  AssistantMemoryBackend(this.server);

  final ServerPort server;

  @override
  String get id => 'assistant';

  @override
  Future<void> write(MemoryNote note) => server.assistantMemoryWrite(note);

  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) async {
    if (k <= 0 || query.trim().isEmpty) return const [];
    return server.assistantMemoryRecall(query, k: k);
  }

  /// The assistant does not report a count through the bridge.
  @override
  Future<MemorySummary> summary() async => MemorySummary(backend: id);
}
