import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/wake/wake_phrase.dart';

void main() {
  group('normaliseWakePhrase', () {
    test('lower-cases, strips punctuation, collapses and trims spaces', () {
      expect(normaliseWakePhrase('  Hey,   ILLUNIS!  '), 'hey illunis');
      expect(normaliseWakePhrase('hey-illunis.'), 'hey illunis');
      expect(normaliseWakePhrase('What’s up, Orion?'), 'whats up orion');
      expect(normaliseWakePhrase('hey_illunis'), 'hey illunis');
      expect(normaliseWakePhrase('\tok\n  nova '), 'ok nova');
    });
  });

  group('validateWakePhrase accepts', () {
    for (final p in [
      'Hey Illunis',
      'hey illunis!',
      'okay nova',
      'wake up orion',
      'good morning moonlight',
      'listen little star',
      'hello there captain',
    ]) {
      test(p, () => expect(validateWakePhrase(p), isNull));
    }

    test('exactly 40 characters', () {
      final p = 'abcdefghijklmnopqrs tuvwxyzabcdefghijklm'; // 2 words, 40 chars
      expect(p.length, maxWakeChars);
      expect(validateWakePhrase(p), isNull);
    });
  });

  group('validateWakePhrase rejects', () {
    final cases = <String, WakePhraseRejection>{
      '': WakePhraseRejection.empty,
      ' ?! ': WakePhraseRejection.empty,
      'illunis': WakePhraseRejection.tooFewWords,
      'hey there illunis my friend': WakePhraseRejection.tooManyWords,
      'supercalifragilistic expialidociousness x': WakePhraseRejection.tooLong,
      'hey r2d2': WakePhraseRejection.unsupportedCharacters,
      'hey léa': WakePhraseRejection.unsupportedCharacters,
      'come here': WakePhraseRejection.commonWords,
      'what is that': WakePhraseRejection.commonWords,
      'hey there': WakePhraseRejection.bareGreeting,
      'good morning': WakePhraseRejection.bareGreeting,
      'hello everyone': WakePhraseRejection.bareGreeting,
      'thank you': WakePhraseRejection.bareGreeting,
      'Hi, Hello!': WakePhraseRejection.bareGreeting,
    };
    cases.forEach((p, why) {
      test('"$p" -> ${why.name}', () => expect(validateWakePhrase(p), why));
    });

    test('41 characters', () {
      final p = 'abcdefghijklmnopqrst tuvwxyzabcdefghijklm';
      expect(p.length, maxWakeChars + 1);
      expect(validateWakePhrase(p), WakePhraseRejection.tooLong);
    });
  });

  group('WakePhrase', () {
    test('tryCreate normalises and matches engine output', () {
      final p = WakePhrase.tryCreate('  Hey, Illunis! ')!;
      expect(p.text, 'hey illunis');
      expect(p.words, ['hey', 'illunis']);
      expect(p.matches('HEY_ILLUNIS'), isTrue);
      expect(p.matches('hey illunis.'), isTrue);
      expect(p.matches('hey'), isFalse);
    });

    test('tryCreate returns null for a rejected phrase', () {
      expect(WakePhrase.tryCreate('hey there'), isNull);
    });
  });
}
