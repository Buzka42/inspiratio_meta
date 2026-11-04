import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/voice/council_trigger.dart';

// Synthetic questions only.
void main() {
  group('councilTrigger', () {
    test('explicit asks', () {
      for (final t in [
        'Ask the council about my sleep',
        'can you ask the experts whether I should run before breakfast',
        'run this by the council',
        'consult the specialists',
        'ask the council',
      ]) {
        expect(councilTrigger(t), CouncilTrigger.explicit, reason: t);
      }
    });

    test('big questions: a topic plus a depth cue', () {
      for (final t in [
        'Why do I keep waking up at 3am?',
        'What should I eat before a long run?',
        'Is it normal for my resting heart rate to go up after training?',
        'I have been so stressed lately and I cannot focus at work',
        'How can I improve my sleep routine during the week?',
        'What is the difference between cardio and strength for weight loss?',
      ]) {
        expect(councilTrigger(t), CouncilTrigger.offer, reason: t);
      }
    });

    test('ordinary turns: no topic, no depth cue, or too short', () {
      for (final t in [
        'What time is it?',
        'Tell me a joke',
        'I slept well',
        'Thanks',
        'Why is the sky blue today, I wonder?',
        'I went for a run this morning and it was nice',
        'Good night',
        '',
      ]) {
        expect(councilTrigger(t), CouncilTrigger.none, reason: t);
      }
    });
  });

  group('explicitCouncilQuestion', () {
    test('takes the words after the council phrase', () {
      expect(explicitCouncilQuestion('Ask the council about my sleep getting worse'), 'my sleep getting worse');
      expect(explicitCouncilQuestion('ask the experts whether I should fast'), 'i should fast');
    });

    test('too little left gives null', () {
      expect(explicitCouncilQuestion('ask the council'), isNull);
      expect(explicitCouncilQuestion('ask the council about that'), isNull);
      expect(explicitCouncilQuestion('what time is it'), isNull);
    });
  });

  test('isAnalysisRequest', () {
    for (final t in ['How have I been doing?', 'how am i doing', 'Give me my 21 day analysis', 'how was my week']) {
      expect(isAnalysisRequest(t), isTrue, reason: t);
    }
    for (final t in ['how are you doing', 'what is the weather', 'how have you been']) {
      expect(isAnalysisRequest(t), isFalse, reason: t);
    }
  });
}
