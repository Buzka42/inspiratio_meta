/// Splits reply text into sentences so the first can play while the rest is
/// prepared. Rule: break after `.`, `!` or `?` when whitespace follows.
/// A known abbreviation or a capital initial before the `.` does not
/// break. A number such as 3.5 never breaks (no whitespace after the dot).
library;

/// Lower-case abbreviations, without the final dot, that never end a sentence.
const abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'e.g',
  'i.e', 'a.m', 'p.m', 'approx', 'mt', 'fig',
};

final _end = RegExp(r'[.!?]+(?=\s)');

List<String> splitSentences(String text) {
  final out = <String>[];
  var start = 0;
  for (final m in _end.allMatches(text)) {
    if (m[0] == '.' && _isAbbreviation(text.substring(start, m.start))) continue;
    _add(out, text.substring(start, m.end));
    start = m.end;
  }
  _add(out, text.substring(start));
  return out;
}

bool _isAbbreviation(String before) {
  final word = RegExp(r'(\S+)$').firstMatch(before)?.group(1);
  if (word == null) return false;
  final w = word.replaceFirst(RegExp(r'^[("\x27]+'), '');
  // Capital initial, as in "J. Smith". "I" and "A" are words, so they end.
  if (RegExp(r'^[B-HJ-Z]$').hasMatch(w)) return true;
  return abbreviations.contains(w.toLowerCase());
}

void _add(List<String> out, String part) {
  final t = part.trim();
  if (t.isNotEmpty) out.add(t);
}
