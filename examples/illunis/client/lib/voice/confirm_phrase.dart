/// Spoken approval rules (docs/DESIGN.md). An
/// assistant action goes ahead only on an explicit "yes", "do it" or "go
/// ahead". Anything else cancels: other words, a hedge, or any "no",
/// "wait" or "don't" mixed in. Pure, no I/O.
library;

/// Lower case, apostrophes dropped ("don't" -> "dont"), everything that is
/// not a letter or digit becomes a space, spaces collapsed.
String normaliseSpoken(String raw) => raw
    .toLowerCase()
    .replaceAll(RegExp(r"[’'`]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

List<String> spokenWords(String raw) {
  final n = normaliseSpoken(raw);
  return n.isEmpty ? const [] : n.split(' ');
}

/// Any of these anywhere in the answer cancels, even next to a yes.
const confirmVetoWords = {
  'no', 'not', 'nope', 'nah', 'wait', 'dont', 'stop', 'cancel', 'hold', 'never', 'later', 'but',
  'maybe', 'wont', 'shouldnt', 'actually', 'instead', 'except', 'unless',
};

/// The only phrases that confirm, as word sequences.
const _confirmPhrases = [
  ['yes'],
  ['do', 'it'],
  ['go', 'ahead'],
];

/// Words allowed next to a confirm phrase ("yes please", "go ahead now").
const _confirmFillers = {'please', 'now'};

/// True only when the whole answer is made of the confirm phrases ("yes",
/// "do it", "go ahead", or several of them, like "yes, go ahead"), plus
/// "please" or "now". Empty text, any veto word and any other word are
/// false.
bool isConfirmPhrase(String raw) {
  final words = spokenWords(raw);
  if (words.isEmpty || words.any(confirmVetoWords.contains)) return false;
  var i = 0, phrases = 0;
  outer:
  while (i < words.length) {
    if (_confirmFillers.contains(words[i])) {
      i++;
      continue;
    }
    for (final p in _confirmPhrases) {
      if (i + p.length <= words.length && _matches(words, i, p)) {
        i += p.length;
        phrases++;
        continue outer;
      }
    }
    return false;
  }
  return phrases > 0;
}

bool _matches(List<String> words, int at, List<String> phrase) {
  for (var k = 0; k < phrase.length; k++) {
    if (words[at + k] != phrase[k]) return false;
  }
  return true;
}

/// Answer to an offer such as "Want me to ask the council?": true for a
/// clear yes, false for a clear no, null when it is neither (the transcript
/// is then left for normal handling). Looser than [isConfirmPhrase]: an
/// offer only leads to advice, never to an action.
bool? parseOfferAnswer(String raw) {
  final words = spokenWords(raw);
  if (words.isEmpty || words.length > 6) return null;
  final w = words.toSet();
  final n = words.join(' ');
  final yes = w.any(_offerYes.contains) || n.contains('go ahead') || n.contains('do it');
  final no = w.any(_offerNo.contains);
  if (yes == no) return null;
  return yes;
}

const _offerYes = {'yes', 'yeah', 'yep', 'sure', 'please', 'ok', 'okay', 'alright'};
const _offerNo = {'no', 'nope', 'nah', 'dont', 'not', 'skip', 'never'};
