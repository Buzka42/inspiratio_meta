/// Long-term memory backends (docs/DESIGN.md).
/// [LocalMemoryBackend] keeps notes on the phone and is the default;
/// [AssistantMemoryBackend] stores them in the connected assistant through
/// the Worker; [VpsMemoryBackend] is the paid VPS brain, not built yet.
library;

import 'memory_note.dart';

/// Recall returns at most this many notes unless asked otherwise.
const defaultRecallK = 5;

/// A backend that cannot serve the call. [code] is a fixed string for logs;
/// [message] is short and safe to speak.
class MemoryUnavailable implements Exception {
  const MemoryUnavailable(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'MemoryUnavailable($code)';
}

/// What a backend holds, for "what do you remember" and settings readback.
class MemorySummary {
  const MemorySummary({required this.backend, this.noteCount, this.available = true});

  /// The backend's [MemoryBackend.id].
  final String backend;

  /// Null when the backend does not report a count.
  final int? noteCount;
  final bool available;

  /// One short sentence, without any note text.
  String get spoken {
    if (!available) return 'That memory is not available yet.';
    final where = switch (backend) {
      'assistant' => 'with your assistant',
      'vps' => 'on your private server',
      _ => 'on this phone',
    };
    final n = noteCount;
    if (n == null) return 'Long-term memory is kept $where.';
    return 'I keep $n ${n == 1 ? 'note' : 'notes'} $where.';
  }
}

abstract class MemoryBackend {
  /// Stable id: `phone`, `assistant` or `vps`.
  String get id;

  /// Stores [note]. Throws on failure ([MemoryUnavailable] or the transport's
  /// error); callers decide whether to swallow it.
  Future<void> write(MemoryNote note);

  /// Up to [k] notes relevant to [query], best first. Never expired notes.
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK});

  Future<MemorySummary> summary();
}

/// The paid VPS brain. Interface only until it exists: every call refuses.
class VpsMemoryBackend implements MemoryBackend {
  const VpsMemoryBackend();

  static const unavailable = MemoryUnavailable('vps_not_available', 'not available yet');

  @override
  String get id => 'vps';

  @override
  Future<void> write(MemoryNote note) async => throw unavailable;

  @override
  Future<List<RecalledMemory>> recall(String query, {int k = defaultRecallK}) async =>
      throw unavailable;

  @override
  Future<MemorySummary> summary() async => const MemorySummary(backend: 'vps', available: false);
}
