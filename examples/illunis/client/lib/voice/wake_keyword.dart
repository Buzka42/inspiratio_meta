/// User-chosen wake keyword: validation rule and normalised exact matcher.
library;

/// Common words that would cause frequent false wakes.
const commonWords = <String>{
  'about', 'after', 'again', 'also', 'back', 'been', 'come', 'could', 'from',
  'good', 'have', 'hello', 'here', 'just', 'know', 'like', 'look', 'make',
  'more', 'okay', 'only', 'over', 'please', 'really', 'right', 'some',
  'that', 'them', 'then', 'there', 'they', 'thing', 'think', 'this', 'time',
  'want', 'well', 'were', 'what', 'when', 'where', 'which', 'will', 'with',
  'would', 'yeah', 'your',
};

const minKeywordLetters = 4;

final _letters = RegExp(r'^[a-z]+$');

enum KeywordRejection { tooShort, notLetters, commonWord }

/// Returns why [raw] is rejected, or null when it is acceptable.
KeywordRejection? validateKeyword(String raw) {
  final word = raw.trim().toLowerCase();
  if (!_letters.hasMatch(word)) {
    return word.isEmpty ? KeywordRejection.tooShort : KeywordRejection.notLetters;
  }
  if (word.length < minKeywordLetters) return KeywordRejection.tooShort;
  if (commonWords.contains(word)) return KeywordRejection.commonWord;
  return null;
}

class WakeKeyword {
  const WakeKeyword._(this.word);

  /// Lower-cased, trimmed keyword.
  final String word;

  /// Returns a keyword, or null when [validateKeyword] rejects [raw].
  static WakeKeyword? tryCreate(String raw) =>
      validateKeyword(raw) == null ? WakeKeyword._(raw.trim().toLowerCase()) : null;

  /// True only when [fragment] is the keyword once both sides are
  /// normalised (see [normaliseFragment]), so "Altair!" matches but
  /// "hey altair" does not.
  bool matches(String fragment) => normaliseFragment(fragment) == normaliseFragment(word);
}

final _notKept = RegExp(r"[^\p{L}\p{N}'\s]", unicode: true);
final _spaces = RegExp(r'\s+');

/// Lower-cases, maps the typographic apostrophe to ', replaces every other
/// character that is not a letter, digit, apostrophe or space with a space,
/// then collapses and trims spaces. Speech engines add punctuation
/// ("altair.") that exact matching would reject.
String normaliseFragment(String raw) => raw
    .toLowerCase()
    .replaceAll('\u2019', "'")
    .replaceAll(_notKept, ' ')
    .replaceAll(_spaces, ' ')
    .trim();
