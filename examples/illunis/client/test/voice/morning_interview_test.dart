import 'package:flutter_test/flutter_test.dart';

import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/voice/wake_keyword.dart';

InterviewState run(List<InterviewAnswer> answers) =>
    answers.fold(const InterviewState(), advance);

void main() {
  test('steps run in order and every step has a prompt', () {
    var s = const InterviewState();
    final seen = <InterviewStep>[s.step];
    for (final a in <InterviewAnswer>[
      const Acknowledge(),
      const ProactiveAnswer(ProactiveMode.proactive),
      const KeywordAnswer('Vega'),
      const PersonalityAnswer('socratic-tutor', skillPackId: 'breathwork'),
      const ConfirmAnswer(true),
    ]) {
      expect(s.prompt, isNotEmpty);
      s = advance(s, a);
      seen.add(s.step);
    }
    expect(seen, InterviewStep.values);
    expect(s.prompt, isNotEmpty);
    expect(s.proactive, isTrue);
    expect(s.keyword!.word, 'vega');
    expect(s.personalityId, 'socratic-tutor');
    expect(s.skillPackId, 'breathwork');
  });

  test('"wait" leaves proactive off', () {
    final s = run(const [Acknowledge(), ProactiveAnswer(ProactiveMode.wait)]);
    expect(s.step, InterviewStep.askWakeKeyword);
    expect(s.proactive, isFalse);
  });

  test('proactive is off by default', () {
    expect(const InterviewState().proactive, isFalse);
  });

  test('keyword is validated by WakeKeyword', () {
    final base = run(const [Acknowledge(), ProactiveAnswer(ProactiveMode.wait)]);

    final short = advance(base, const KeywordAnswer('sky'));
    expect(short.step, InterviewStep.askWakeKeyword);
    expect(short.keywordRejection, KeywordRejection.tooShort);
    expect(short.keyword, isNull);
    expect(short.prompt, contains('four letters'));

    final common = advance(short, const KeywordAnswer('hello'));
    expect(common.step, InterviewStep.askWakeKeyword);
    expect(common.keywordRejection, KeywordRejection.commonWord);

    final ok = advance(common, const KeywordAnswer('Altair'));
    expect(ok.step, InterviewStep.askDigestPersonality);
    expect(ok.keywordRejection, isNull);
    expect(ok.keyword!.matches('ALTAIR'), isTrue);
  });

  test('wrong answer type for the step is ignored', () {
    final s = run(const [Acknowledge()]);
    expect(advance(s, const KeywordAnswer('Vega')), same(s));
    expect(advance(s, const ConfirmAnswer(true)), same(s));
  });

  test('declining at confirm restarts questions with proactive off', () {
    final s = run(const [
      Acknowledge(),
      ProactiveAnswer(ProactiveMode.proactive),
      KeywordAnswer('Vega'),
      PersonalityAnswer('personal-coach'),
      ConfirmAnswer(false),
    ]);
    expect(s.step, InterviewStep.askProactive);
    expect(s.proactive, isFalse);
    expect(s.keyword, isNull);
  });

  test('confirm prompt reflects choices', () {
    final s = run(const [
      Acknowledge(),
      ProactiveAnswer(ProactiveMode.wait),
      KeywordAnswer('Vega'),
      PersonalityAnswer('productivity-advisor'),
    ]);
    expect(s.step, InterviewStep.confirm);
    expect(s.prompt, contains('wait until you speak'));
    expect(s.prompt, contains('vega'));
    expect(s.prompt, contains('productivity-advisor'));
  });

  test('typed (voice off) skips the wake keyword step with the default keyword', () {
    var s = advance(const InterviewState(), const Acknowledge(), typed: true);
    s = advance(s, const ProactiveAnswer(ProactiveMode.wait), typed: true);
    expect(s.step, InterviewStep.askDigestPersonality);
    expect(s.keyword?.word, typedDefaultKeyword);
    s = advance(s, const PersonalityAnswer('calm_guide'), typed: true);
    expect(s.promptFor(typed: true), isNot(contains('wake word')));
    expect(s.promptFor(typed: true), contains('write to me'));
    s = advance(s, const ConfirmAnswer(true), typed: true);
    expect(s.promptFor(typed: true), 'All set. Type a message whenever you need me.');
    expect(s.prompt, 'All set. Say your wake word whenever you need me.');
  });
}
