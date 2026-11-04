/// Turns a [WakePhrase] into a sherpa-onnx keyword line, e.g.
/// "▁HEY ▁ILL UN IS @HEY_ILLUNIS", replacing the offline
/// `sherpa-onnx-cli text2token --tokens-type bpe` step so the user's phrase
/// works at runtime. Pure Dart: SentencePiece BPE (merge the adjacent pair
/// whose merged piece has the highest vocab score, until none is left).
library;

import 'wake_phrase.dart';

const _wordStart = '▁'; // ▁

class BpeKeywordEncoder {
  BpeKeywordEncoder(this._scores, {this.upperCase = true});

  /// Parses a SentencePiece `bpe.vocab` file (`piece<TAB>score` per line).
  /// Export it from the model's bpe.model with `spm_export_vocab` if the
  /// model package does not ship one.
  factory BpeKeywordEncoder.fromVocab(String vocab, {bool upperCase = true}) {
    final scores = <String, double>{};
    for (final line in vocab.split('\n')) {
      final tab = line.lastIndexOf('\t');
      if (tab <= 0) continue;
      final score = double.tryParse(line.substring(tab + 1).trim());
      if (score != null) scores[line.substring(0, tab)] = score;
    }
    return BpeKeywordEncoder(scores, upperCase: upperCase);
  }

  final Map<String, double> _scores;

  /// The English gigaspeech KWS models use upper-case pieces.
  final bool upperCase;

  /// BPE pieces for [phrase]. Throws [FormatException] when a character has
  /// no piece in the vocab.
  List<String> encode(WakePhrase phrase) =>
      [for (final w in phrase.words) ..._encodeWord(upperCase ? w.toUpperCase() : w)];

  /// Keyword line for the spotter: pieces, optional boost (`:`) and
  /// threshold (`#`), then `@` and the phrase with "_" for spaces so the
  /// spotter reports it back in one token.
  String keywordLine(WakePhrase phrase, {double? boost, double? threshold}) {
    final parts = [
      ...encode(phrase),
      if (boost != null) ':$boost',
      if (threshold != null) '#$threshold',
      '@${phrase.text.replaceAll(' ', '_')}',
    ];
    return parts.join(' ');
  }

  List<String> _encodeWord(String word) {
    final symbols = [_wordStart, ...word.split('')];
    while (true) {
      var best = -1;
      var bestScore = double.negativeInfinity;
      for (var i = 0; i < symbols.length - 1; i++) {
        final score = _scores[symbols[i] + symbols[i + 1]];
        if (score != null && score > bestScore) {
          best = i;
          bestScore = score;
        }
      }
      if (best < 0) break;
      symbols.replaceRange(best, best + 2, [symbols[best] + symbols[best + 1]]);
    }
    final unknown = symbols.where((s) => !_scores.containsKey(s));
    if (unknown.isNotEmpty) {
      throw FormatException('No BPE piece for ${unknown.join(', ')} in "$word"');
    }
    return symbols;
  }
}
