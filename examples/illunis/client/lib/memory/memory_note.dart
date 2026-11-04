/// Memory note shapes shared by the writer, the backends and the server port.
/// A [MemoryNote] is what is written; a [RecalledMemory] is what recall
/// returns and what /turn and /reply receive from the phone.
library;

/// Memory kinds (server/src/memory.js KINDS). The server shows `hypothesis`
/// to the model as "observation" (turn.js LABELS); `fact` is never written
/// from a conversation, because nothing said there is verified.
enum MemoryLabel {
  note('note'),
  observation('hypothesis');

  const MemoryLabel(this.kind);
  final String kind;

  static MemoryLabel? fromKind(Object? kind) =>
      values.where((l) => l.kind == kind).firstOrNull;
}

const memorySource = 'conversation';

/// One long-term memory note. [toJson] is the body of POST /memory/write and
/// POST /assistant/memory/write.
class MemoryNote {
  const MemoryNote({
    required this.text,
    required this.label,
    required this.confidence,
    this.expiresAt,
    this.source = memorySource,
  });

  final String text;
  final MemoryLabel label;
  final double confidence;

  /// Null: the note does not expire.
  final DateTime? expiresAt;
  final String source;

  Map<String, dynamic> toJson() => {
        'text': text,
        'kind': label.kind,
        'source': source,
        'confidence': confidence,
        'expires_at': expiresAt?.toUtc().toIso8601String(),
      };

  /// Null for a malformed entry (unknown kind, empty text, bad numbers).
  static MemoryNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final text = j['text'], label = MemoryLabel.fromKind(j['kind']), c = j['confidence'];
    if (text is! String || text.trim().isEmpty || label == null || c is! num) return null;
    final e = j['expires_at'];
    final expires = e is String ? DateTime.tryParse(e) : null;
    if (e != null && expires == null) return null;
    final src = j['source'];
    return MemoryNote(
        text: text,
        label: label,
        confidence: c.toDouble().clamp(0, 1),
        expiresAt: expires,
        source: src is String && src.isNotEmpty ? src : memorySource);
  }

  RecalledMemory toRecalled() =>
      RecalledMemory(text: text, kind: label.kind, confidence: confidence, source: source);
}

/// One recalled memory: `{text, kind, confidence, source}`.
class RecalledMemory {
  const RecalledMemory({
    required this.text,
    required this.kind,
    required this.confidence,
    required this.source,
  });

  final String text;
  final String kind;
  final double confidence;
  final String source;

  Map<String, dynamic> toJson() =>
      {'text': text, 'kind': kind, 'confidence': confidence, 'source': source};

  /// Null for an entry without text; other fields fall back to safe values.
  static RecalledMemory? fromJson(Object? j) {
    if (j is! Map) return null;
    final text = j['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final kind = j['kind'], c = j['confidence'], src = j['source'];
    return RecalledMemory(
      text: text,
      kind: kind is String && kind.isNotEmpty ? kind : 'note',
      confidence: c is num ? c.toDouble().clamp(0, 1) : 0.5,
      source: src is String && src.isNotEmpty ? src : 'unknown',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecalledMemory &&
      other.text == text &&
      other.kind == kind &&
      other.confidence == confidence &&
      other.source == source;

  @override
  int get hashCode => Object.hash(text, kind, confidence, source);
}
