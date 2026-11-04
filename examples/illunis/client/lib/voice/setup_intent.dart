/// Spoken setup changes after the interview: "change my alarm to 6:45",
/// "change my wake word to Vega". Pure Dart, in the style of
/// moon/voice_zoom.dart. Unknown text returns null.
library;

enum SetupTarget { alarm, wakeKeyword }

class SetupIntent {
  const SetupIntent(this.target, [this.value]);
  final SetupTarget target;

  /// The new value as spoken ("6:45", "vega."), or null when the user only
  /// named what to change ("change my alarm"); the caller then asks for it.
  final String? value;
}

const _verb = r'(?:change|set|move|update|make|switch|reset)';
const _alarm = r'(?:my |the )?(?:morning )?alarm(?: clock)?(?: time)?';
const _keyword = r'(?:my |the )?(?:wake ?(?:up )?word|wake keyword|keyword|wake-word)';

final _alarmIntent = RegExp('^$_verb $_alarm(?: (?:to|for|at) (.+))?\$');
final _wakeMeIntent = RegExp(r'^wake me(?: up)? at (.+)$');
final _keywordIntent = RegExp('^$_verb $_keyword(?: (?:to|is|as) (.+))?\$');

/// Keeps characters a time or a word can contain (digits, ':' and '.' for
/// "6:45" and "6.45"); drops a trailing full stop and polite filler.
String _normalise(String raw) {
  var t = raw
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r"[^a-z0-9:.' -]+"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  while (t.endsWith('.')) {
    t = t.substring(0, t.length - 1).trim();
  }
  for (final lead in const ['please ', 'can you ', 'could you ', 'i want to ', "i'd like to "]) {
    if (t.startsWith(lead)) t = t.substring(lead.length);
  }
  if (t.endsWith(' please')) t = t.substring(0, t.length - ' please'.length);
  return t;
}

SetupIntent? parseSetupIntent(String transcript) {
  final t = _normalise(transcript);
  final a = _alarmIntent.firstMatch(t) ?? _wakeMeIntent.firstMatch(t);
  if (a != null) return SetupIntent(SetupTarget.alarm, a[1]);
  final k = _keywordIntent.firstMatch(t);
  if (k != null) return SetupIntent(SetupTarget.wakeKeyword, k[1]);
  return null;
}
