/// The breathwork library (build plan B7, PLAN.md decisions 2026-10-28 and
/// 2026-10-28b). A technique is found only by the name or an alias the user
/// typed: there is no ranking, no "you might like" and no default pick.
/// Basic techniques list in progression order. Advanced ones are offered
/// only when the user set themselves as advanced in onboarding (a stored
/// answer, never inferred). Holotropic can be named and explained but never
/// started.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'technique.dart';

/// Asset folder written by tool/sync_breath_content.sh.
const breathAssetDir = 'assets/breath/';

/// The schema copied beside the techniques; not a technique.
const breathSchemaAsset = '${breathAssetDir}technique.schema.json';

/// Why a named technique cannot start a session.
enum BreathRefusal {
  /// Holotropic: explained with the clinician notice, never guided.
  referenceOnly,

  /// Advanced, and the user has not said they practise at an advanced level.
  advancedOnly,

  /// In the library, but with no playable timing (`available: false`).
  unavailable,
}

class BreathLibrary {
  BreathLibrary(Iterable<Technique> techniques) : _all = List.unmodifiable(techniques) {
    for (final t in _all) {
      for (final n in [t.name, ...t.aliases]) {
        _names.putIfAbsent(normaliseBreathName(n), () => t);
      }
    }
  }

  /// Parses the JSON text of each technique file.
  factory BreathLibrary.fromJsonStrings(Iterable<String> files) => BreathLibrary(
      files.map((s) => Technique.fromJson(jsonDecode(s) as Map<String, Object?>)));

  /// Loads every technique in [breathAssetDir] from [bundle].
  static Future<BreathLibrary> loadBundled([AssetBundle? bundle]) async {
    final b = bundle ?? rootBundle;
    final manifest = await AssetManifest.loadFromAssetBundle(b);
    final paths = manifest
        .listAssets()
        .where((p) => p.startsWith(breathAssetDir) && p.endsWith('.json') && p != breathSchemaAsset)
        .toList()
      ..sort();
    return BreathLibrary.fromJsonStrings(await Future.wait(paths.map(b.loadString)));
  }

  final List<Technique> _all;
  final _names = <String, Technique>{};

  List<Technique> get all => _all;

  /// Every normalised name and alias, for matching typed requests.
  Iterable<String> get names => _names.keys;

  Technique? byId(String id) {
    for (final t in _all) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The technique whose name or alias is [typed] (case, punctuation and a
  /// leading "a" or "the" or a trailing "session" ignored). Null otherwise:
  /// a near miss is not guessed.
  Technique? match(String typed) {
    final n = normaliseBreathName(typed)
        .replaceFirst(RegExp(r'^(?:a|an|the|some|my) '), '')
        .replaceFirst(RegExp(r' (?:session|exercise|practice)$'), '');
    return _names[n];
  }

  /// The basic techniques in progression order (decision 2026-10-28b).
  List<Technique> basics() => _all.where((t) => t.isBasic).toList()
    ..sort((a, b) => (a.progressionOrder ?? 99).compareTo(b.progressionOrder ?? 99));

  /// What the library lists when the user asks to see it: the basics in
  /// order, then the advanced ones by name only for an advanced practitioner.
  List<Technique> listFor({required bool advanced}) => [
        ...basics(),
        if (advanced) ...(_all.where((t) => !t.isBasic).toList()..sort((a, b) => a.name.compareTo(b.name))),
      ];

  /// Null when [t] may start a session for this user, else the reason.
  BreathRefusal? refusal(Technique t, {required bool advanced}) {
    if (t.screens.contains(ScreenKind.holotropic)) return BreathRefusal.referenceOnly;
    if (!t.isBasic && !advanced) return BreathRefusal.advancedOnly;
    if (!t.playable) return BreathRefusal.unavailable;
    return null;
  }
}
