/// Spoken interview answers: transcript text to the answer each setup step
/// takes. Pure Dart. Every parser returns null for text it cannot read, and
/// the caller re-asks the same step.
library;

import 'alarm_digest.dart';
import 'morning_interview.dart';

final _notWord = RegExp(r"[^a-z0-9' ]+");
final _spaces = RegExp(r'\s+');

/// Lower case, typographic apostrophe folded, everything but letters, digits,
/// apostrophes and spaces turned into spaces, spaces collapsed.
String normaliseAnswer(String raw) => raw
    .toLowerCase()
    .replaceAll('’', "'")
    .replaceAll(_notWord, ' ')
    .replaceAll(_spaces, ' ')
    .trim();

Set<String> _words(String raw) => normaliseAnswer(raw).split(' ').where((w) => w.isNotEmpty).toSet();

/// Any speech moves past the greeting.
Acknowledge? parseAcknowledge(String raw) =>
    normaliseAnswer(raw).isEmpty ? null : const Acknowledge();

// "productive" and "pro active" are common Whisper tiny mishearings of
// "proactive" (device test 2026-10-25).
const _proactiveWords = {'proactive', 'proactively', 'productive', 'offer', 'own'};
const _waitWords = {'wait', 'until'};

/// "proactive" or "offer advice on your own" versus "wait". Both or neither
/// is unreadable.
ProactiveAnswer? parseProactive(String raw) {
  final w = _words(normaliseAnswer(raw).replaceAll('pro active', 'proactive'));
  final pro = w.any(_proactiveWords.contains);
  final wait = w.any(_waitWords.contains);
  if (pro == wait) return null;
  return ProactiveAnswer(pro ? ProactiveMode.proactive : ProactiveMode.wait);
}

const _keywordLeads = [
  'my wake word is ',
  'the wake word is ',
  'the word is ',
  'call it ',
  'call me ',
  "let's use ",
  'how about ',
  'use ',
];

/// One word, optionally after a short lead ("use Vega"). The word itself is
/// not validated here: [advance] runs [validateKeyword] and its rejection
/// drives the specific re-prompt (too short, too common, not letters).
/// More than one word is unreadable.
KeywordAnswer? parseKeyword(String raw) {
  var t = normaliseAnswer(raw);
  for (final lead in _keywordLeads) {
    if (t.startsWith(lead)) {
      t = t.substring(lead.length);
      break;
    }
  }
  if (t.endsWith(' please')) t = t.substring(0, t.length - ' please'.length);
  if (t.isEmpty || t.contains(' ')) return null;
  return KeywordAnswer(t);
}

/// Spoken name of a content id: `personal_coach` -> `personal coach`.
String spokenName(String id) => id.replaceAll('_', ' ');

/// Short forms that name one entry only.
const _personalityAliases = {
  'calm': 'calm_guide',
  'planner': 'daily_planner',
  'dream': 'dream_companion',
  'drill sergeant': 'drill_sergeant_trainer',
  'sergeant': 'drill_sergeant_trainer',
  'coach': 'personal_coach',
  'productivity': 'productivity_advisor',
  'advisor': 'productivity_advisor',
  'journal': 'reflective_journal_guide',
  'socratic': 'socratic_tutor',
  'tutor': 'socratic_tutor',
};

const _skillAliases = {
  'breathing': 'breathwork',
  'habits': 'habit_building',
  'habit': 'habit_building',
  'meditation': 'meditation_basics',
  'meditate': 'meditation_basics',
  'weights': 'weight_training',
  'strength': 'weight_training',
  'wind down': 'wind_down_routine',
};

bool _hasPhrase(String text, String phrase) => ' $text '.contains(' $phrase ');

/// The one id in [ids] whose spoken name (or else one alias) appears in
/// [raw] as whole words. None, or more than one, is unreadable.
String? _matchId(String raw, Set<String> ids, Map<String, String> aliases) {
  final t = normaliseAnswer(raw);
  if (t.isEmpty) return null;
  var hits = {for (final id in ids) if (_hasPhrase(t, spokenName(id))) id};
  if (hits.isEmpty) {
    hits = {
      for (final e in aliases.entries)
        if (ids.contains(e.value) && _hasPhrase(t, e.key)) e.value
    };
  }
  return hits.length == 1 ? hits.single : null;
}

/// A personality id from [ids] (the content list), or null.
String? parsePersonality(String raw, Set<String> ids) => _matchId(raw, ids, _personalityAliases);

/// A skill pack answer: [id] null means the user wants none.
class SkillPackChoice {
  const SkillPackChoice(this.id);
  final String? id;
}

const _noneAnswers = {
  'none', 'no', 'nope', 'nothing', 'skip', 'no thanks', 'no thank you',
  'none please', 'no skill pack', 'none thanks', 'none thank you',
};

/// A skill pack from [ids], "none", or null.
SkillPackChoice? parseSkillPack(String raw, Set<String> ids) {
  if (_noneAnswers.contains(normaliseAnswer(raw))) return const SkillPackChoice(null);
  final id = _matchId(raw.replaceAll('-', ' '), ids, _skillAliases);
  return id == null ? null : SkillPackChoice(id);
}

// "y" and "n" are typed short forms (voice off).
const _yesWords = {'yes', 'y', 'yeah', 'yep', 'yup', 'correct', 'right', 'sure', 'ok', 'okay', 'confirm'};
const _noWords = {'no', 'n', 'nope', 'wrong', 'not', 'incorrect'};

/// "yes" or "no", spoken or typed. Both or neither is unreadable.
ConfirmAnswer? parseConfirm(String raw) {
  final w = _words(raw);
  final yes = w.any(_yesWords.contains);
  final no = w.any(_noWords.contains);
  if (yes == no) return null;
  return ConfirmAnswer(yes);
}

// ---- Alarm time ------------------------------------------------------------

const _units = {
  'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6,
  'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12,
  'thirteen': 13, 'fourteen': 14, 'fifteen': 15, 'sixteen': 16,
  'seventeen': 17, 'eighteen': 18, 'nineteen': 19,
};
const _tens = {'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50};
const _fillers = {'at', 'for', 'the', 'a', 'please', 'oclock', 'clock', 'sharp', 'minutes', 'minute'};

/// A spoken or written clock time: "7:30", "7.30", "730", "seven thirty",
/// "six forty-five", "six oh five", "half past seven", "quarter to seven",
/// "ten past six", "noon", "midnight", with optional "am", "pm", "in the
/// morning" or "in the evening". Without am or pm the hour is taken as said
/// (0-23). Anything else, or an out-of-range time, is null.
LocalTime? parseAlarmTime(String raw) {
  var t = raw
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r'\ba\.\s?m\b\.?'), ' am ')
      .replaceAll(RegExp(r'\bp\.\s?m\b\.?'), ' pm ')
      .replaceAll("o'clock", ' oclock ')
      .replaceAllMapped(RegExp(r'(\d)\s*[:.h]\s*(\d)'), (m) => '${m[1]} ${m[2]}')
      .replaceAllMapped(RegExp(r'(\d)(am|pm)\b'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
      .replaceAll(_spaces, ' ')
      .trim();
  bool? pm;
  for (final (phrase, isPm) in const [
    ('in the morning', false),
    ('in the afternoon', true),
    ('in the evening', true),
    ('at night', true),
  ]) {
    if (t.endsWith(' $phrase')) {
      t = t.substring(0, t.length - phrase.length - 1);
      pm = isPm;
    }
  }
  final tokens = [for (final w in t.split(' ')) if (w.isNotEmpty && !_fillers.contains(w)) w];
  if (tokens.isNotEmpty && (tokens.last == 'am' || tokens.last == 'pm')) {
    if (pm != null) return null;
    pm = tokens.removeLast() == 'pm';
  }
  if (tokens.length == 1 && tokens.single == 'noon') return pm == null ? const LocalTime(12, 0) : null;
  if (tokens.length == 1 && tokens.single == 'midnight') return pm == null ? const LocalTime(0, 0) : null;

  final relative = _relative(tokens);
  if (relative != null) return _clock(relative.$1, relative.$2, pm);

  final nums = _numbers(tokens);
  if (nums == null || nums.isEmpty || nums.length > 2) return null;
  if (nums.length == 1) {
    final (n, digits) = nums.single;
    if (digits >= 3) return _clock(n ~/ 100, n % 100, pm); // "730", "0645"
    return _clock(n, 0, pm);
  }
  final (h, _) = nums[0];
  final (m, mDigits) = nums[1];
  if (mDigits == 1) return null; // "7:5" is not a written time.
  return _clock(h, m, pm);
}

/// "half past seven", "quarter to seven", "ten past six", "twenty to eight".
(int, int)? _relative(List<String> tokens) {
  final i = tokens.indexWhere((w) => w == 'past' || w == 'to' || w == 'after' || w == 'before');
  if (i <= 0 || i == tokens.length - 1) return null;
  final before = tokens.sublist(0, i);
  int? mins;
  if (before.length == 1 && before.single == 'half') mins = 30;
  if (before.length == 1 && before.single == 'quarter') mins = 15;
  mins ??= _singleNumber(before);
  final hour = _singleNumber(tokens.sublist(i + 1));
  if (mins == null || hour == null || mins < 1 || mins > 30) return null;
  final forward = tokens[i] == 'past' || tokens[i] == 'after';
  if (forward) return (hour, mins);
  return (hour == 0 ? 23 : hour - 1, 60 - mins);
}

int? _singleNumber(List<String> tokens) {
  final n = _numbers(tokens);
  return n != null && n.length == 1 ? n.single.$1 : null;
}

/// Groups tokens into numbers: (value, written digit count; 0 for words, 2
/// for a word minute after "oh"). "twenty one" is 21, "seven thirty five" is
/// 7 and 35, "six oh five" is 6 and 5. Null when a token is not a number.
List<(int, int)>? _numbers(List<String> tokens) {
  final out = <(int, int)>[];
  for (var i = 0; i < tokens.length; i++) {
    final w = tokens[i];
    final next = i + 1 < tokens.length ? tokens[i + 1] : null;
    final nextUnit = next == null ? null : _units[next];
    if (RegExp(r'^\d+$').hasMatch(w)) {
      out.add((int.parse(w), w.length));
    } else if ((w == 'oh' || w == 'o') && out.isNotEmpty && nextUnit != null && nextUnit < 10) {
      out.add((nextUnit, 2));
      i++;
    } else if (_tens.containsKey(w)) {
      if (nextUnit != null && nextUnit >= 1 && nextUnit <= 9) {
        out.add((_tens[w]! + nextUnit, 0));
        i++;
      } else {
        out.add((_tens[w]!, 0));
      }
    } else if (_units.containsKey(w)) {
      out.add((_units[w]!, 0));
    } else {
      return null;
    }
  }
  return out;
}

LocalTime? _clock(int hour, int minute, bool? pm) {
  if (minute < 0 || minute > 59) return null;
  var h = hour;
  if (pm != null) {
    if (h < 1 || h > 12) return null;
    if (pm && h < 12) h += 12;
    if (!pm && h == 12) h = 0;
  }
  if (h < 0 || h > 23) return null;
  return LocalTime(h, minute);
}

/// "07:30".
String formatClock(LocalTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Reads [formatClock] output back; null when malformed or out of range.
LocalTime? parseClock(String? s) {
  final m = s == null ? null : RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  return h < 24 && min < 60 ? LocalTime(h, min) : null;
}
