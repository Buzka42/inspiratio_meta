/// User-chosen wake phrase (2 to 4 words): normalisation and validation.
/// Pure functions only. The single-word rule in lib/voice/wake_keyword.dart
/// is the older matcher for the transcript path and is left as it is.
library;

const minWakeWords = 2;
const maxWakeWords = 4;
const maxWakeChars = 40;

/// Greeting words. A phrase made only of these (plus [wakeCommonWords]) is
/// a bare greeting and would wake on everyday speech.
const wakeGreetingWords = <String>{
  'hi', 'hey', 'hello', 'hiya', 'howdy', 'yo', 'greetings', 'morning',
  'afternoon', 'evening', 'night', 'bye', 'goodbye', 'ok', 'okay', 'cheers',
  'thanks', 'thank', 'welcome', 'sup',
};

/// Frequent English words. A phrase made only of these is rejected.
const wakeCommonWords = <String>{
  'a', 'about', 'after', 'again', 'all', 'also', 'am', 'an', 'and', 'are',
  'at', 'back', 'be', 'been', 'but', 'by', 'can', 'come', 'could', 'day',
  'do', 'for', 'from', 'get', 'go', 'good', 'got', 'have', 'he', 'her',
  'here', 'him', 'how', 'i', 'if', 'in', 'is', 'it', 'its', 'just', 'know',
  'let', 'lets', 'like', 'look', 'make', 'me', 'more', 'my', 'no', 'not',
  'now', 'of', 'oh', 'on', 'one', 'only', 'or', 'our', 'out', 'over',
  'please', 'really', 'right', 'say', 'see', 'she', 'so', 'some', 'stop',
  'tell', 'that', 'thats', 'the', 'them', 'then', 'there', 'they', 'thing',
  'think', 'this', 'time', 'to', 'up', 'us', 'want', 'was', 'we', 'well',
  'were', 'what', 'whats', 'when', 'where', 'which', 'who', 'why', 'will',
  'with', 'would', 'yeah', 'yes', 'you', 'your', 'everyone', 'everybody',
  'guys', 'dear', 'friend', 'man',
};

enum WakePhraseRejection {
  empty,

  /// Fewer than [minWakeWords] words.
  tooFewWords,

  /// More than [maxWakeWords] words.
  tooManyWords,

  /// Longer than [maxWakeChars] characters after normalisation.
  tooLong,

  /// Contains digits or non a-z letters (the KWS model is English BPE).
  unsupportedCharacters,

  /// Only common words ("come here", "thank you").
  commonWords,

  /// Only greeting words, optionally with common words ("hey there",
  /// "good morning").
  bareGreeting,
}

final _apostrophes = RegExp("['‘’`]");
final _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);
final _spaces = RegExp(r'\s+');
final _azWord = RegExp(r'^[a-z]+$');

/// Lower-cases, drops apostrophes ("what's" -> "whats"), turns every other
/// punctuation or symbol into a space ("hey-illunis!" -> "hey illunis"),
/// then collapses and trims spaces.
String normaliseWakePhrase(String raw) => raw
    .toLowerCase()
    .replaceAll(_apostrophes, '')
    .replaceAll(_punctuation, ' ')
    .replaceAll(_spaces, ' ')
    .trim();

/// Why [raw] cannot be a wake phrase, or null when it is acceptable.
WakePhraseRejection? validateWakePhrase(String raw) {
  final phrase = normaliseWakePhrase(raw);
  if (phrase.isEmpty) return WakePhraseRejection.empty;
  final words = phrase.split(' ');
  if (!words.every(_azWord.hasMatch)) {
    return WakePhraseRejection.unsupportedCharacters;
  }
  if (words.length < minWakeWords) return WakePhraseRejection.tooFewWords;
  if (words.length > maxWakeWords) return WakePhraseRejection.tooManyWords;
  if (phrase.length > maxWakeChars) return WakePhraseRejection.tooLong;
  final distinctive = words.where(
      (w) => !wakeCommonWords.contains(w) && !wakeGreetingWords.contains(w));
  if (distinctive.isEmpty) {
    return words.any(wakeGreetingWords.contains)
        ? WakePhraseRejection.bareGreeting
        : WakePhraseRejection.commonWords;
  }
  return null;
}

/// A validated, normalised wake phrase.
class WakePhrase {
  const WakePhrase._(this.text);

  /// Normalised text, e.g. "hey illunis".
  final String text;

  List<String> get words => text.split(' ');

  /// Returns a phrase, or null when [validateWakePhrase] rejects [raw].
  static WakePhrase? tryCreate(String raw) => validateWakePhrase(raw) == null
      ? WakePhrase._(normaliseWakePhrase(raw))
      : null;

  /// True when [heard] (engine output, any case or punctuation, "_" for
  /// spaces) is this phrase.
  bool matches(String heard) => normaliseWakePhrase(heard) == text;

  @override
  bool operator ==(Object other) => other is WakePhrase && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'WakePhrase($text)';
}
