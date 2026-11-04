/// The user's alarm: wall-clock time, on/off, and the digest's personality and
/// skill pack. Every [AlarmSettings] instance is valid; [AlarmSettings.validate]
/// is the only way to make one. Saved through the guarded [StateStore].
///
/// Log lines carry a code only (`alarm: <code>`), never a stored value.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';
import '../voice/alarm_digest.dart';

typedef AlarmLog = void Function(String line);

/// Store key. Kept here because persistence.dart is outside this section.
const alarmSettingsKey = 'alarm_settings';

/// Personality ids shipped in content/personalities (checked 2026-10-23).
const knownPersonalityIds = {
  'calm_guide',
  'daily_planner',
  'dream_companion',
  'drill_sergeant_trainer',
  'personal_coach',
  'productivity_advisor',
  'reflective_journal_guide',
  'socratic_tutor',
};

/// Skill pack ids shipped in content/skills (checked 2026-10-23).
const knownSkillPackIds = {
  'breathwork',
  'habit_building',
  'meditation_basics',
  'motivation',
  'weight_training',
  'wind_down_routine',
};

const defaultPersonalityId = 'calm_guide';

/// Log codes, so tests and logs agree on the wording.
abstract final class AlarmCodes {
  static const invalidTime = 'invalid_time';
  static const unknownPersonality = 'unknown_personality';
  static const unknownSkillPack = 'unknown_skill_pack';
  static const badSaved = 'bad_saved_settings';
}

class AlarmSettings {
  const AlarmSettings._({
    required this.hour,
    required this.minute,
    required this.enabled,
    required this.personalityId,
    this.skillPackId,
  });

  final int hour;
  final int minute;
  final bool enabled;
  final String personalityId;
  final String? skillPackId;

  LocalTime get time => LocalTime(hour, minute);

  /// Null when the time is out of range (hour 0-23, minute 0-59). An unknown
  /// personality becomes [defaultPersonalityId]; an unknown skill pack is
  /// dropped. Each correction logs its code.
  static AlarmSettings? validate({
    required int hour,
    required int minute,
    bool enabled = true,
    String? personalityId,
    String? skillPackId,
    AlarmLog? log,
  }) {
    final l = log ?? debugPrint;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      l('alarm: ${AlarmCodes.invalidTime}');
      return null;
    }
    var pid = personalityId;
    if (pid == null || !knownPersonalityIds.contains(pid)) {
      l('alarm: ${AlarmCodes.unknownPersonality}');
      pid = defaultPersonalityId;
    }
    var sid = skillPackId;
    if (sid != null && !knownSkillPackIds.contains(sid)) {
      l('alarm: ${AlarmCodes.unknownSkillPack}');
      sid = null;
    }
    return AlarmSettings._(
        hour: hour, minute: minute, enabled: enabled, personalityId: pid, skillPackId: sid);
  }

  AlarmSettings copyWith({bool? enabled}) => AlarmSettings._(
      hour: hour,
      minute: minute,
      enabled: enabled ?? this.enabled,
      personalityId: personalityId,
      skillPackId: skillPackId);

  Map<String, Object?> toJson() => {
        'hour': hour,
        'minute': minute,
        'enabled': enabled,
        'personality_id': personalityId,
        'skill_pack_id': ?skillPackId,
      };

  /// Null for malformed JSON, wrong types or an invalid time.
  static AlarmSettings? fromJsonString(String raw, {AlarmLog? log}) {
    final l = log ?? debugPrint;
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      j = null;
    }
    if (j is! Map<String, dynamic> ||
        j['hour'] is! int ||
        j['minute'] is! int ||
        j['enabled'] is! bool ||
        (j['personality_id'] != null && j['personality_id'] is! String) ||
        (j['skill_pack_id'] != null && j['skill_pack_id'] is! String)) {
      l('alarm: ${AlarmCodes.badSaved}');
      return null;
    }
    return validate(
      hour: j['hour'] as int,
      minute: j['minute'] as int,
      enabled: j['enabled'] as bool,
      personalityId: j['personality_id'] as String?,
      skillPackId: j['skill_pack_id'] as String?,
      log: l,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlarmSettings &&
      other.hour == hour &&
      other.minute == minute &&
      other.enabled == enabled &&
      other.personalityId == personalityId &&
      other.skillPackId == skillPackId;

  @override
  int get hashCode => Object.hash(hour, minute, enabled, personalityId, skillPackId);
}

/// Reads and writes [AlarmSettings] under [alarmSettingsKey].
class AlarmSettingsStore {
  AlarmSettingsStore(this.store, {AlarmLog? log}) : _log = log ?? debugPrint;

  final StateStore store;
  final AlarmLog _log;

  /// Null when nothing is saved or the saved value is bad. A bad value is
  /// ignored (logged by code), never thrown.
  Future<AlarmSettings?> load() async {
    final raw = await store.getString(alarmSettingsKey);
    if (raw == null) return null;
    return AlarmSettings.fromJsonString(raw, log: _log);
  }

  Future<void> save(AlarmSettings s) => store.setString(alarmSettingsKey, jsonEncode(s.toJson()));
}
