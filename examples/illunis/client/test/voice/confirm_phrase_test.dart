import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/voice/confirm_phrase.dart';

void main() {
  group('isConfirmPhrase', () {
    test('the three phrases confirm, normalised', () {
      for (final t in ['yes', 'Yes.', 'YES!', 'do it', 'Do it.', 'go ahead', 'Go ahead!', '  yes  ']) {
        expect(isConfirmPhrase(t), isTrue, reason: t);
      }
    });

    test('phrases may combine and take please or now', () {
      for (final t in ['yes, go ahead', 'yes do it', 'yes please', 'go ahead now', 'please do it', 'yes yes']) {
        expect(isConfirmPhrase(t), isTrue, reason: t);
      }
    });

    test('a veto word anywhere cancels, even with a yes', () {
      for (final t in [
        'yes, wait',
        'no',
        'no, yes',
        "yes but don't",
        "don't do it",
        'do not do it',
        'wait go ahead',
        'yes, hold on',
        'yes actually no',
        'go ahead, no wait',
        'yes cancel',
        'stop',
        "Don’t go ahead",
      ]) {
        expect(isConfirmPhrase(t), isFalse, reason: t);
      }
    });

    test('anything else cancels: other words, near misses, hedges, silence', () {
      for (final t in [
        '',
        '   ',
        'yeah',
        'yep',
        'sure',
        'ok',
        'okay go',
        'do',
        'go',
        'ahead',
        'yes to the other one',
        'send it',
        'i guess',
        'yes send a different message',
        'what?',
        'please',
        'now',
      ]) {
        expect(isConfirmPhrase(t), isFalse, reason: t);
      }
    });
  });

  group('parseOfferAnswer', () {
    test('clear yes and no; anything else is null', () {
      expect(parseOfferAnswer('yes please'), isTrue);
      expect(parseOfferAnswer('sure'), isTrue);
      expect(parseOfferAnswer('go ahead'), isTrue);
      expect(parseOfferAnswer('no thanks'), isFalse);
      expect(parseOfferAnswer('nah'), isFalse);
      expect(parseOfferAnswer('yes no'), isNull);
      expect(parseOfferAnswer('what time is it'), isNull);
      expect(parseOfferAnswer('yes I would like to hear about something completely different now'), isNull);
      expect(parseOfferAnswer(''), isNull);
    });
  });
}
