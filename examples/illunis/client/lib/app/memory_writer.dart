/// After a completed turn, stores one short memory note in the selected
/// long-term [MemoryBackend] (on the phone by default, or the connected
/// assistant). The note follows server/src/memory.js validateMemory. Never
/// the full transcript: a statement the user made about themselves is kept in their
/// own words (capped); anything else becomes one inferred observation that
/// joins the start of the question with the first sentence of the answer.
library;

import '../memory/memory_backend.dart';
import '../memory/memory_note.dart';

export '../memory/memory_note.dart' show MemoryLabel, MemoryNote, memorySource;

const memoryWriteFailed = 'memory_write_failed';
const userStatementConfidence = 0.8;
const observationConfidence = 0.5;
const observationLifetime = Duration(days: 30);

/// Transcripts with fewer words are not remembered.
const minMemoryWords = 4;
const _maxStatementChars = 200;
const _maxQuestionWords = 12;
const _maxQuestionChars = 100;
const _maxAnswerChars = 160;

final _space = RegExp(r'\s+');

/// First-person words (English and Polish) that mark a statement about the
/// speaker. Matched as whole lowercase words.
const _selfWords = {
  'i', "i'm", 'im', "i've", "i'd", "i'll", 'my', 'me', 'mine', 'myself',
  'jestem', 'mam', 'mój', 'moja', 'moje', 'mojego', 'mojej', 'mnie', 'mi', 'czuję', 'lubię',
  'byłem', 'byłam', 'chcę', 'muszę',
};

/// Openings that make an utterance a question, whatever its last character.
const _questionWords = {
  'what', 'why', 'how', 'when', 'where', 'who', 'which', 'should', 'can', 'could', 'would',
  'do', 'does', 'did', 'is', 'are', 'will', 'co', 'czy', 'jak', 'dlaczego', 'kiedy', 'gdzie', 'ile',
};

int wordCount(String text) => text.trim().isEmpty ? 0 : text.trim().split(_space).length;

List<String> _words(String text) =>
    text.toLowerCase().split(RegExp(r"[^\p{L}\p{N}']+", unicode: true)).where((w) => w.isNotEmpty).toList();

/// True when [transcript] is something the user said about themselves, not a
/// question.
bool isUserStatement(String transcript) {
  final t = transcript.trim();
  if (t.endsWith('?')) return false;
  final words = _words(t);
  if (words.isEmpty || _questionWords.contains(words.first)) return false;
  return words.any(_selfWords.contains);
}

String _cap(String text, int max) {
  final t = text.trim().replaceAll(_space, ' ');
  return t.length <= max ? t : '${t.substring(0, max).trimRight()}...';
}

String _firstSentence(String text) {
  final t = text.trim().replaceAll(_space, ' ');
  final m = RegExp(r'^.*?[.!?](?=\s|$)').firstMatch(t);
  return _cap(m?.group(0) ?? t, _maxAnswerChars);
}

/// The note for a completed turn, or null when nothing should be stored:
/// a crisis or safety-replaced turn, a transcript under [minMemoryWords]
/// words, or an observation with no answer to summarise.
MemoryNote? noteForTurn({
  required String transcript,
  required String answer,
  required DateTime now,
  bool crisis = false,
  bool replaced = false,
}) {
  if (crisis || replaced || wordCount(transcript) < minMemoryWords) return null;
  if (isUserStatement(transcript)) {
    return MemoryNote(
        text: 'User said: ${_cap(transcript, _maxStatementChars)}',
        label: MemoryLabel.note,
        confidence: userStatementConfidence);
  }
  final reply = _firstSentence(answer);
  if (reply.isEmpty) return null;
  final asked = transcript.trim().split(_space);
  final question = _cap(
      asked.length <= _maxQuestionWords ? asked.join(' ') : '${asked.take(_maxQuestionWords).join(' ')}...',
      _maxQuestionChars);
  return MemoryNote(
      text: 'User asked: $question Illunis answered: $reply',
      label: MemoryLabel.observation,
      confidence: observationConfidence,
      expiresAt: now.toUtc().add(observationLifetime));
}

/// Writes [noteForTurn] to [backend]. Never throws: any failure logs the
/// fixed code [memoryWriteFailed] only, never the text or the error.
class MemoryWriter {
  MemoryWriter(this.backend, {required this.log, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Usually a SelectedMemoryBackend, so the voice setting takes effect at once.
  final MemoryBackend backend;
  final void Function(String) log;
  final DateTime Function() _clock;

  /// True when a note was stored.
  Future<bool> afterTurn({
    required String transcript,
    required String answer,
    bool crisis = false,
    bool replaced = false,
  }) async {
    try {
      final note = noteForTurn(
          transcript: transcript, answer: answer, now: _clock(), crisis: crisis, replaced: replaced);
      if (note == null) return false;
      await backend.write(note);
      return true;
    } catch (_) {
      log(memoryWriteFailed);
      return false;
    }
  }
}
