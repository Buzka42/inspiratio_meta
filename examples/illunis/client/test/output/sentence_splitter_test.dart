import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/output/sentence_splitter.dart';

// Synthetic text only.
void main() {
  test('splits on . ! ? followed by space', () {
    expect(splitSentences('Good morning. Ready? Let us go! Now.'),
        ['Good morning.', 'Ready?', 'Let us go!', 'Now.']);
  });

  test('never splits inside a number', () {
    expect(splitSentences('Walk 3.5 km today. Then rest.'), ['Walk 3.5 km today.', 'Then rest.']);
    expect(splitSentences('Version 1.2.3 is out'), ['Version 1.2.3 is out']);
  });

  test('keeps abbreviations as-is', () {
    expect(splitSentences('Ask Dr. Lee at 7 a.m. tomorrow. Bring water, e.g. a bottle.'),
        ['Ask Dr. Lee at 7 a.m. tomorrow.', 'Bring water, e.g. a bottle.']);
    expect(splitSentences('Mr. and Mrs. Grey vs. the hill, etc. Done.'),
        ['Mr. and Mrs. Grey vs. the hill, etc. Done.']);
    expect(splitSentences('J. R. Smith wrote it. Read it.'), ['J. R. Smith wrote it.', 'Read it.']);
  });

  test('"I" and "A" at a sentence end still split', () {
    expect(splitSentences('So do I. Then go.'), ['So do I.', 'Then go.']);
  });

  test('punctuation runs, newlines, no final mark, empty input', () {
    expect(splitSentences('Really?! Yes...\nOk'), ['Really?!', 'Yes...', 'Ok']);
    expect(splitSentences('No end mark'), ['No end mark']);
    expect(splitSentences('   '), isEmpty);
    expect(splitSentences('End.'), ['End.']);
  });
}
