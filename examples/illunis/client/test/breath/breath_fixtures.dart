// Loads the synced breath assets from disk (no asset bundle), plus a small
// synthetic technique builder for timing tests.
import 'dart:io';

import 'package:illunis_client/breath/breath_library.dart';
import 'package:illunis_client/breath/technique.dart';

BreathLibrary loadAssetLibrary() {
  final files = Directory('assets/breath')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json') && !f.path.endsWith('technique.schema.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return BreathLibrary.fromJsonStrings(files.map((f) => f.readAsStringSync()));
}

Technique synthetic({
  String id = 'synthetic',
  TechniqueLevel level = TechniqueLevel.basic,
  List<BreathPhase> phases = const [BreathPhase(BreathPhaseKind.inhale, 4), BreathPhase(BreathPhaseKind.exhale, 6)],
  int durationS = 60,
  List<Cue> cues = const [],
  bool available = true,
}) =>
    Technique(
      id: id,
      name: 'Synthetic $id',
      aliases: const [],
      kind: TechniqueKind.breath,
      level: level,
      evidence: Evidence.weak,
      available: available,
      durationS: durationS,
      countInCycles: 3,
      pacing: Pacing(phases: phases, rateBpm: 6),
      cues: cues,
      screens: const [ScreenKind.standard],
      stopPrompts: const ['You can stop at any time.'],
      copy: const TechniqueCopy(intent: 'Synthetic intent.', end: 'Synthetic end.', notice: 'Synthetic notice.'),
    );
