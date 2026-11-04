/// The agent's spec as the app sees it: a value class parsed from the
/// Worker's JSON, and the proposal and refusal models. Changes are made in
/// the chat (spec_chat.dart); there is no settings screen.
/// Guardrails are text from the server; the app never sends them.
library;

const skillIds = ['breathwork', 'sleep', 'diet', 'training', 'medical', 'reading', 'habits'];
const memoryModes = ['off', 'phone', 'hermes'];
const proactivityModes = ['never', 'daily', 'events'];
const brains = ['auto', 'meta', 'baseten', 'nebius'];
const retentionChoices = [7, 30, 90, 365];

class SettingsSpec {
  const SettingsSpec({
    this.version = 1,
    this.skills = const {'breathwork': true, 'sleep': true, 'diet': false, 'training': false, 'medical': false, 'reading': true, 'habits': true},
    this.memoryMode = 'phone',
    this.retentionDays = 30,
    this.proactivity = 'daily',
    this.brain = 'auto',
  });

  final int version;
  final Map<String, bool> skills;
  final String memoryMode, proactivity, brain;
  final int retentionDays;

  factory SettingsSpec.fromJson(Object? j) {
    if (j is! Map) return const SettingsSpec();
    const d = SettingsSpec();
    String pick(Object? v, List<String> ok, String def) => v is String && ok.contains(v) ? v : def;
    final s = j['skills'], m = j['memory'], p = j['proactivity'];
    final days = m is Map ? m['retention_days'] : null;
    return SettingsSpec(
      version: j['version'] is int ? j['version'] as int : d.version,
      skills: {for (final k in skillIds) k: s is Map && s[k] is bool ? s[k] as bool : d.skills[k]!},
      memoryMode: pick(m is Map ? m['mode'] : null, memoryModes, d.memoryMode),
      retentionDays: days is int && days >= 1 && days <= 365 ? days : d.retentionDays,
      proactivity: pick(p is Map ? p['mode'] : null, proactivityModes, d.proactivity),
      brain: pick(j['brain'], brains, d.brain),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'skills': skills,
        'memory': {'mode': memoryMode, 'retention_days': retentionDays},
        'proactivity': {'mode': proactivity},
        'brain': brain,
      };
}

/// One line of a diff: a dotted [path] and its old and new value.
class SpecDiffEntry {
  const SpecDiffEntry(this.path, this.from, this.to);
  final String path;
  final Object? from, to;

  static SpecDiffEntry? fromJson(Object? j) =>
      j is Map && j['path'] is String ? SpecDiffEntry(j['path'] as String, j['from'], j['to']) : null;
}

/// A change waiting for the user's yes. [readback] is the Worker's own
/// plain-language line, never the bot's words.
class SpecProposal {
  const SpecProposal(
      {required this.changeId, required this.baseVersion, required this.diff, this.readback = '', this.expiresAt});
  final String changeId, readback;
  final int baseVersion;
  final List<SpecDiffEntry> diff;

  /// When the Worker drops the pending change (`expires_at`, ms since the
  /// epoch); null when the answer carried none.
  final DateTime? expiresAt;

  static SpecProposal? fromJson(Map<String, dynamic> j) {
    final id = j['change_id'], d = j['diff'];
    if (id is! String || id.isEmpty || d is! List) return null;
    final rb = j['readback'], exp = j['expires_at'];
    return SpecProposal(
      changeId: id,
      baseVersion: j['base_version'] is int ? j['base_version'] as int : 0,
      diff: [for (final e in d) ?SpecDiffEntry.fromJson(e)],
      readback: rb is String ? rb : '',
      expiresAt: exp is num
          ? DateTime.fromMillisecondsSinceEpoch(exp.toInt(), isUtc: true)
          : exp is String
              ? DateTime.tryParse(exp)
              : null,
    );
  }
}

/// A change the Worker refused (422): no diff exists. Each entry is
/// `(path, reason)`.
class SpecRefused implements Exception {
  const SpecRefused(this.refused);
  final List<(String, String)> refused;

  static SpecRefused fromJson(Map<String, dynamic> j) {
    final r = j['refused'];
    return SpecRefused([
      if (r is List)
        for (final e in r)
          if (e is Map) ('${e['path'] ?? ''}', '${e['reason'] ?? 'refused'}'),
    ]);
  }

  @override
  String toString() => 'SpecRefused(${refused.length})';
}

class KnowledgeSource {
  const KnowledgeSource({required this.id, required this.title, this.origin = '', this.bank = ''});
  final String id, title, origin, bank;

  static KnowledgeSource? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['title'] is! String) return null;
    return KnowledgeSource(
        id: j['id'] as String,
        title: j['title'] as String,
        origin: j['origin'] is String ? j['origin'] as String : '',
        bank: j['bank'] is String ? j['bank'] as String : '');
  }
}

/// GET /spec and POST /spec/apply answer: the spec, the fixed guardrail
/// lines, and the Hermes mirror state (`synced`, `pending` or `off`).
class SpecState {
  const SpecState({required this.spec, this.guardrails = const [], this.mirror = 'off'});
  final SettingsSpec spec;
  final List<String> guardrails;
  final String mirror;

  factory SpecState.fromJson(Map<String, dynamic> j) {
    final g = j['guardrails'];
    return SpecState(
      spec: SettingsSpec.fromJson(j['spec'] ?? j),
      guardrails: g is String
          ? [for (final l in g.split('\n')) if (l.trim().isNotEmpty) l.trim()]
          : g is List
              ? [for (final l in g) if (l is String && l.trim().isNotEmpty) l.trim()]
              : const [],
      mirror: j['mirror'] is String ? j['mirror'] as String : 'off',
    );
  }
}
