import 'package:flutter_test/flutter_test.dart';

import 'package:illunis_client/voice/wake_keyword.dart';

void main() {
  group('matcher', () {
    final k = WakeKeyword.tryCreate('Altair')!;

    test('exact, case-insensitive, trimmed', () {
      expect(k.matches('altair'), isTrue);
      expect(k.matches('  ALTAIR \n'), isTrue);
      expect(k.matches('AlTaIr'), isTrue);
    });

    test('rejects anything but the exact keyword', () {
      expect(k.matches('altai'), isFalse);
      expect(k.matches('altairs'), isFalse);
      expect(k.matches('hey altair'), isFalse);
      expect(k.matches(''), isFalse);
    });

    test('ignores punctuation and extra spaces from speech engines', () {
      expect(k.matches('altair.'), isTrue);
      expect(k.matches('Altair!'), isTrue);
      expect(k.matches('  ALTAIR  '), isTrue);
      expect(k.matches('"Altair?"'), isTrue);
    });

    test('punctuation does not make a different word match', () {
      expect(k.matches('vega.'), isFalse);
      expect(k.matches('Altair, hello'), isFalse);
      expect(k.matches('...'), isFalse);
    });
  });

  group('validation rule', () {
    test('accepts uncommon words of 4+ letters', () {
      expect(validateKeyword('Vega'), isNull);
      expect(validateKeyword(' orion '), isNull);
    });

    test('rejects words shorter than 4 letters', () {
      expect(validateKeyword('sky'), KeywordRejection.tooShort);
      expect(validateKeyword(''), KeywordRejection.tooShort);
      expect(WakeKeyword.tryCreate('hey'), isNull);
    });

    test('rejects common words', () {
      expect(validateKeyword('hello'), KeywordRejection.commonWord);
      expect(validateKeyword('OKAY'), KeywordRejection.commonWord);
      expect(WakeKeyword.tryCreate('please'), isNull);
    });

    test('rejects non-letters and multiple words', () {
      expect(validateKeyword('star1'), KeywordRejection.notLetters);
      expect(validateKeyword('north star'), KeywordRejection.notLetters);
    });
  });
}
