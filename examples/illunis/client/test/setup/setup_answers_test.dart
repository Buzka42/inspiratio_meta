import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/alarm/alarm_settings.dart';
import 'package:illunis_client/voice/alarm_digest.dart';
import 'package:illunis_client/voice/morning_interview.dart';
import 'package:illunis_client/voice/setup_answers.dart';
import 'package:illunis_client/voice/setup_intent.dart';
import 'package:illunis_client/voice/wake_keyword.dart';

// Synthetic transcripts only.
String? hm(String s) {
  final t = parseAlarmTime(s);
  return t == null ? null : formatClock(t);
}

void main() {
  test('proactive or wait', () {
    expect(parseProactive('Proactive.')?.mode, ProactiveMode.proactive);
    expect(parseProactive('offer advice on your own')?.mode, ProactiveMode.proactive);
    expect(parseProactive('Pro-active.')?.mode, ProactiveMode.proactive);
    expect(parseProactive('Productive')?.mode, ProactiveMode.proactive);
    expect(parseProactive('Wait.')?.mode, ProactiveMode.wait);
    expect(parseProactive('wait until I speak')?.mode, ProactiveMode.wait);
    expect(parseProactive('maybe'), isNull);
    expect(parseProactive('proactive, no, wait'), isNull); // both
  });

  test('keyword is one word after an optional lead', () {
    expect(parseKeyword('Altair.')?.keyword, 'altair');
    expect(parseKeyword('use Vega please')?.keyword, 'vega');
    expect(parseKeyword('my wake word is Deneb')?.keyword, 'deneb');
    expect(parseKeyword('hey there altair'), isNull);
    expect(parseKeyword(''), isNull);
  });

  test('a common word as the keyword is rejected', () {
    final a = parseKeyword('Hello!')!;
    expect(validateKeyword(a.keyword), KeywordRejection.commonWord);
    final s = advance(const InterviewState(step: InterviewStep.askWakeKeyword), a);
    expect(s.step, InterviewStep.askWakeKeyword);
    expect(s.keyword, isNull);
    expect(s.prompt, contains('too common'));
  });

  test('personality from the content list', () {
    expect(parsePersonality('The personal coach, please.', knownPersonalityIds), 'personal_coach');
    expect(parsePersonality('Socratic tutor', knownPersonalityIds), 'socratic_tutor');
    expect(parsePersonality('a calm guide', knownPersonalityIds), 'calm_guide');
    expect(parsePersonality('drill sergeant', knownPersonalityIds), 'drill_sergeant_trainer');
    expect(parsePersonality('coach', knownPersonalityIds), 'personal_coach');
    expect(parsePersonality('a pirate', knownPersonalityIds), isNull);
    expect(parsePersonality('guide', knownPersonalityIds), isNull); // two guides
    expect(parsePersonality('coach or tutor', knownPersonalityIds), isNull);
  });

  test('skill pack or none', () {
    expect(parseSkillPack('Breathwork.', knownSkillPackIds)?.id, 'breathwork');
    expect(parseSkillPack('the wind-down routine', knownSkillPackIds)?.id, 'wind_down_routine');
    expect(parseSkillPack('weight training', knownSkillPackIds)?.id, 'weight_training');
    final none = parseSkillPack('None, thanks.', knownSkillPackIds);
    expect(none, isNotNull);
    expect(none!.id, isNull);
    expect(parseSkillPack('juggling', knownSkillPackIds), isNull);
  });

  test('confirm yes or no', () {
    expect(parseConfirm('Yes.')?.yes, isTrue);
    expect(parseConfirm("yeah that's right")?.yes, isTrue);
    expect(parseConfirm('No.')?.yes, isFalse);
    expect(parseConfirm('nope')?.yes, isFalse);
    expect(parseConfirm('purple'), isNull);
    expect(parseConfirm('yes no'), isNull);
  });

  test('alarm time parser: digits', () {
    expect(hm('7:30'), '07:30');
    expect(hm('7.30'), '07:30');
    expect(hm('6:45 a.m.'), '06:45');
    expect(hm('6:45 p.m.'), '18:45');
    expect(hm('7am'), '07:00');
    expect(hm('730'), '07:30');
    expect(hm('0645'), '06:45');
    expect(hm('19:05'), '19:05');
    expect(hm('at 7:30.'), '07:30');
    expect(hm('12 am'), '00:00');
    expect(hm('12 pm'), '12:00');
  });

  test('alarm time parser: words', () {
    expect(hm('seven thirty'), '07:30');
    expect(hm('Seven thirty.'), '07:30');
    expect(hm('six forty-five'), '06:45');
    expect(hm('six oh five'), '06:05');
    expect(hm('seven'), '07:00');
    expect(hm("seven o'clock"), '07:00');
    expect(hm('seven thirty in the evening'), '19:30');
    expect(hm('twenty one fifteen'), '21:15');
    expect(hm('half past seven'), '07:30');
    expect(hm('quarter to seven'), '06:45');
    expect(hm('ten past six'), '06:10');
    expect(hm('noon'), '12:00');
    expect(hm('midnight'), '00:00');
  });

  test('alarm time parser: rejects', () {
    for (final bad in ['', 'early', '25:00', '7:60', '13 pm', 'seven banana', '7:5', 'twenty five']) {
      expect(parseAlarmTime(bad), isNull, reason: bad);
    }
  });

  test('clock round trip', () {
    expect(formatClock(parseClock('06:45')!), '06:45');
    expect(parseClock('6:45'), isNull);
    expect(parseClock('24:00'), isNull);
    expect(const LocalTime(7, 5).minutesOfDay, 425);
  });

  test('setup intents', () {
    final a = parseSetupIntent('Change my alarm to 6:45.')!;
    expect(a.target, SetupTarget.alarm);
    expect(hm(a.value!), '06:45');
    expect(hm(parseSetupIntent('set the alarm for quarter to seven')!.value!), '06:45');
    expect(parseSetupIntent('wake me up at seven')!.target, SetupTarget.alarm);
    expect(parseSetupIntent('change my alarm')!.value, isNull);

    final k = parseSetupIntent('Please change my wake word to Vega.')!;
    expect(k.target, SetupTarget.wakeKeyword);
    expect(parseKeyword(k.value!)?.keyword, 'vega');
    expect(parseSetupIntent('change the wake word')!.value, isNull);

    expect(parseSetupIntent('what is my alarm'), isNull);
    expect(parseSetupIntent('zoom in on the moon'), isNull);
  });
}
