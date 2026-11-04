/// One breathwork or meditation technique, parsed from a JSON file in
/// assets/breath/ (a copy of content/breathwork/, checked against
/// content/schemas/technique.schema.json). Parsing is strict: a missing or
/// mistyped field throws [FormatException], so a bad copy fails loudly.
library;

enum TechniqueKind { breath, meditation }

enum TechniqueLevel { basic, advanced }

enum Evidence { moderate, weak, practitioner }

/// in = inhale; topUp = a short second inhale; hold = a short, comfortable
/// pause; out = exhale; holdEmpty = empty-lung retention after a full exhale.
enum BreathPhaseKind {
  inhale('in'),
  topUp('top_up'),
  hold('hold'),
  exhale('out'),
  holdEmpty('hold_empty');

  const BreathPhaseKind(this.json);
  final String json;

  bool get isHold => this == hold || this == holdEmpty;
}

/// Screens a technique needs before a session (research section 4).
enum ScreenKind { standard, holds, forceful, holotropic }

ScreenKind _screen(String s) => switch (s) {
      'default' => ScreenKind.standard,
      'holds' => ScreenKind.holds,
      'forceful' => ScreenKind.forceful,
      'holotropic' => ScreenKind.holotropic,
      _ => throw FormatException('bad screen', s),
    };

class BreathPhase {
  const BreathPhase(this.kind, this.seconds);
  final BreathPhaseKind kind;
  final double seconds;
}

class Pacing {
  const Pacing({required this.phases, required this.rateBpm, this.guided = true});
  final List<BreathPhase> phases;
  final double rateBpm;

  /// False: the visual is an ambient reference, not a pace to match.
  final bool guided;

  double get cycleSeconds => phases.fold(0.0, (a, p) => a + p.seconds);
}

class Cue {
  const Cue({required this.atS, required this.text, required this.speak});
  final int atS;
  final String text;
  final bool speak;
}

class TechniqueCopy {
  const TechniqueCopy({required this.intent, required this.end, required this.notice});
  final String intent;
  final String end;

  /// The "not medical advice" and clinician notice.
  final String notice;
}

class Technique {
  const Technique({
    required this.id,
    required this.name,
    required this.aliases,
    required this.kind,
    required this.level,
    required this.evidence,
    required this.available,
    required this.durationS,
    required this.countInCycles,
    required this.pacing,
    required this.cues,
    required this.screens,
    required this.stopPrompts,
    required this.copy,
    this.progressionOrder,
  });

  final String id;
  final String name;
  final List<String> aliases;
  final TechniqueKind kind;
  final TechniqueLevel level;
  final Evidence evidence;
  final bool available;
  final int durationS;
  final int countInCycles;
  final Pacing? pacing;
  final List<Cue> cues;
  final List<ScreenKind> screens;
  final List<String> stopPrompts;
  final TechniqueCopy copy;

  /// Place in the basic pranayama progression (1 to 8), or null.
  final int? progressionOrder;

  bool get isBasic => level == TechniqueLevel.basic;

  /// Available and with timing that can be guided.
  bool get playable => available && pacing != null && durationS > 0;

  factory Technique.fromJson(Map<String, Object?> j) {
    final pacing = j['pacing'];
    final copy = _map(j, 'copy');
    final progression = j['progression'];
    return Technique(
      id: _str(j, 'id'),
      name: _str(j, 'name'),
      aliases: _list(j, 'aliases').map((e) => e as String).toList(growable: false),
      kind: TechniqueKind.values.byName(_str(j, 'kind')),
      level: TechniqueLevel.values.byName(_str(j, 'level')),
      evidence: Evidence.values.byName(_str(j, 'evidence')),
      available: _bool(j, 'available'),
      durationS: _int(j, 'duration_s'),
      countInCycles: _int(j, 'count_in_cycles'),
      pacing: pacing == null ? null : _pacing(pacing as Map<String, Object?>),
      cues: _list(j, 'cues').map((e) {
        final c = e as Map<String, Object?>;
        return Cue(atS: _int(c, 'at_s'), text: _str(c, 'text'), speak: _bool(c, 'speak'));
      }).toList(growable: false),
      screens: _list(j, 'screens').map((e) => _screen(e as String)).toList(growable: false),
      stopPrompts: _list(j, 'stop_prompts').map((e) => e as String).toList(growable: false),
      copy: TechniqueCopy(intent: _str(copy, 'intent'), end: _str(copy, 'end'), notice: _str(copy, 'notice')),
      progressionOrder: progression == null ? null : _int(progression as Map<String, Object?>, 'order'),
    );
  }
}

Pacing _pacing(Map<String, Object?> p) {
  final phases = _list(p, 'phases').map((e) {
    final m = e as Map<String, Object?>;
    final name = _str(m, 'phase');
    final kind = BreathPhaseKind.values.firstWhere((k) => k.json == name,
        orElse: () => throw FormatException('bad phase', name));
    final s = (m['seconds'] as num?)?.toDouble();
    if (s == null || s <= 0) throw const FormatException('bad seconds');
    return BreathPhase(kind, s);
  }).toList(growable: false);
  if (phases.isEmpty) throw const FormatException('no phases');
  final rate = (p['rate_bpm'] as num?)?.toDouble();
  if (rate == null) throw const FormatException('missing rate_bpm');
  return Pacing(phases: phases, rateBpm: rate, guided: (p['guided'] as bool?) ?? true);
}

T _get<T>(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! T) throw FormatException('bad or missing field', k);
  return v;
}

String _str(Map<String, Object?> j, String k) => _get<String>(j, k);
int _int(Map<String, Object?> j, String k) => _get<int>(j, k);
bool _bool(Map<String, Object?> j, String k) => _get<bool>(j, k);
List<Object?> _list(Map<String, Object?> j, String k) => _get<List<Object?>>(j, k);
Map<String, Object?> _map(Map<String, Object?> j, String k) => _get<Map<String, Object?>>(j, k);

/// Lower case, letters only, single spaces: "Longer out-breath" becomes
/// "longer out breath". Matches the normalising in app/view_requests.dart.
String normaliseBreathName(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
