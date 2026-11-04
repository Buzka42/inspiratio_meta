/// Plain-code rules for when the expert council is worth asking
/// (docs/DESIGN.md). The council is slow and
/// costs a quota hit, so it never runs on an ordinary reply:
///
/// - an explicit ask ("ask the council about my sleep") runs it at once;
/// - a big question (a health or lifestyle topic plus a depth cue, such as
///   "why do I keep waking up at 3am") makes Illunis offer it after the
///   normal reply;
/// - "how have I been doing" asks for the 21-day analysis.
///
/// Pure, no I/O.
library;

import 'confirm_phrase.dart' show normaliseSpoken, spokenWords;

/// Topics the council's experts cover (wellbeing and medical fields).
const councilTopicWords = {
  // Sleep and lifestyle.
  'sleep', 'sleeping', 'slept', 'insomnia', 'waking', 'awake', 'snoring', 'nightmares', 'nap', 'naps', 'tired', 'fatigue', 'exhausted', 'energy',
  'caffeine', 'coffee', 'alcohol', 'screen', 'jetlag',
  // Diet and nutrition.
  'diet', 'eating', 'eat', 'food', 'nutrition', 'protein', 'calories', 'carbs', 'sugar', 'fasting', 'weight',
  'vitamin', 'vitamins', 'supplement', 'supplements', 'hydration', 'snacking',
  // Training and movement.
  'training', 'workout', 'workouts', 'exercise', 'running', 'run', 'lifting', 'strength', 'cardio', 'muscle',
  'muscles', 'stretching', 'recovery', 'steps', 'injury', 'sore', 'soreness',
  // Breath, stress and the mind.
  'stress', 'stressed', 'anxiety', 'anxious', 'panic', 'burnout', 'mood', 'meditation', 'breathing', 'breath',
  'focus', 'overwhelmed', 'low', 'lonely',
  // Medical fields (general information only, never a diagnosis).
  'heart', 'pulse', 'hrv', 'blood', 'pressure', 'cholesterol', 'glucose', 'diabetes', 'thyroid', 'hormone',
  'hormones', 'period', 'periods', 'menstrual', 'pregnancy', 'menopause', 'fertility', 'digestion', 'gut',
  'bloating', 'stomach', 'constipation', 'reflux', 'asthma', 'lungs', 'cough', 'skin', 'rash', 'acne', 'eczema',
  'headache', 'headaches', 'migraine', 'migraines', 'pain', 'back', 'knee', 'knees', 'shoulder', 'joints',
  'posture', 'dizzy', 'dizziness',
};

/// Phrases that mark a question needing more than a quick reply.
const councilDepthPhrases = [
  'why', 'should i', 'what should', 'how should', 'how can i', 'how do i', 'best way', 'is it normal',
  'is it bad', 'is it safe', 'is it ok', 'is that normal', 'what causes', 'causing', 'keep', 'keeps',
  'always', 'every night', 'every day', 'every morning', 'for weeks', 'for months', 'lately', 'long term',
  'plan', 'routine', 'program', 'improve', 'compare', 'versus', 'difference between', 'what can i do',
  'worried', 'worse', 'getting better', 'cant', 'cannot', 'struggle', 'struggling',
];

enum CouncilTrigger { none, offer, explicit }

final _explicit = RegExp(
    r'\b(?:ask|consult|check with|run (?:it|this|that) by|get) (?:the |my |your )?(?:council|experts|specialists|expert council)\b');

/// The rule that applies to [raw].
CouncilTrigger councilTrigger(String raw) {
  final n = normaliseSpoken(raw);
  if (n.isEmpty) return CouncilTrigger.none;
  if (_explicit.hasMatch(n)) return CouncilTrigger.explicit;
  final words = n.split(' ');
  if (words.length < 5) return CouncilTrigger.none;
  if (!words.any(councilTopicWords.contains)) return CouncilTrigger.none;
  final padded = ' $n ';
  return councilDepthPhrases.any((p) => padded.contains(' $p ')) ? CouncilTrigger.offer : CouncilTrigger.none;
}

/// The question inside an explicit ask: the words after "about", "whether",
/// "if", "why", "how" or "what", or after the council words. Null when
/// fewer than three words are left ("ask the council"), so the caller uses
/// the question just discussed.
String? explicitCouncilQuestion(String raw) {
  final n = normaliseSpoken(raw);
  final m = _explicit.firstMatch(n);
  if (m == null) return null;
  var rest = n.substring(m.end).trim();
  rest = rest.replaceFirst(RegExp(r'^(?:about|whether|on|regarding|for|to tell me|to look at)\b\s*'), '');
  return spokenWords(rest).length >= 3 ? rest : null;
}

const _analysisPhrases = [
  'how have i been doing', 'how am i doing', 'how have i been', 'how ive been doing', 'how was my week',
  'how were my last', 'how have my last', 'my three week', 'my 3 week', 'three week look', '21 day', '21 days',
  'twenty one day', 'my trends', 'my analysis', 'how is my health trending', 'how are my trends',
];

/// "How have I been doing?", "give me my 21 day analysis".
bool isAnalysisRequest(String raw) {
  final padded = ' ${normaliseSpoken(raw)} ';
  return _analysisPhrases.any((p) => padded.contains(' $p '));
}
