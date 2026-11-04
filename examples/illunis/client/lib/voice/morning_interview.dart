/// First-run spoken interview as a pure step machine. Answers arrive already
/// parsed; turning speech into an [InterviewAnswer] happens elsewhere.
library;

import 'wake_keyword.dart';

enum InterviewStep {
  greet,
  askProactive,
  askWakeKeyword,
  askDigestPersonality,
  confirm,
  done,
}

sealed class InterviewAnswer {
  const InterviewAnswer();
}

/// Any acknowledgement, used to move past the greeting.
class Acknowledge extends InterviewAnswer {
  const Acknowledge();
}

enum ProactiveMode { proactive, wait }

class ProactiveAnswer extends InterviewAnswer {
  const ProactiveAnswer(this.mode);
  final ProactiveMode mode;
}

class KeywordAnswer extends InterviewAnswer {
  const KeywordAnswer(this.keyword);
  final String keyword;
}

class PersonalityAnswer extends InterviewAnswer {
  const PersonalityAnswer(this.personalityId, {this.skillPackId});
  final String personalityId;
  final String? skillPackId;
}

class ConfirmAnswer extends InterviewAnswer {
  const ConfirmAnswer(this.yes);
  final bool yes;
}

class InterviewState {
  const InterviewState({
    this.step = InterviewStep.greet,
    this.proactive = false,
    this.keyword,
    this.personalityId,
    this.skillPackId,
    this.keywordRejection,
  });

  final InterviewStep step;

  /// Off unless the user explicitly chose proactive advice.
  final bool proactive;
  final WakeKeyword? keyword;
  final String? personalityId;
  final String? skillPackId;

  /// Set when the last keyword answer was rejected; drives the re-prompt.
  final KeywordRejection? keywordRejection;

  InterviewState _copy({
    InterviewStep? step,
    bool? proactive,
    WakeKeyword? keyword,
    String? personalityId,
    String? skillPackId,
    KeywordRejection? keywordRejection,
  }) =>
      InterviewState(
        step: step ?? this.step,
        proactive: proactive ?? this.proactive,
        keyword: keyword ?? this.keyword,
        personalityId: personalityId ?? this.personalityId,
        skillPackId: skillPackId ?? this.skillPackId,
        keywordRejection: keywordRejection,
      );

  /// The spoken prompt (voice on).
  String get prompt => promptFor(typed: false);

  /// The prompt for this step. [typed] (voice off, text chat) uses typed
  /// wording and leaves the wake word out of the confirmation.
  String promptFor({required bool typed}) => switch (step) {
        InterviewStep.greet =>
          'Good morning. I am Illunis. I would like to ask you a few short questions to set things up.',
        InterviewStep.askProactive => typed
            ? 'Would you like me to offer advice on my own, or wait until you write to me?'
            : 'Would you like me to offer advice on my own, or wait until you speak to me?',
        InterviewStep.askWakeKeyword => switch (keywordRejection) {
            null =>
              'Choose a word to wake me. Pick something unusual, like the name of a star, such as Vega or Altair.',
            KeywordRejection.tooShort =>
              'That word is too short. Please choose a word with at least four letters.',
            KeywordRejection.notLetters =>
              'Please choose a single word made only of letters.',
            KeywordRejection.commonWord =>
              'That word is too common and would wake me by accident. Please choose a rarer word.',
          },
        InterviewStep.askDigestPersonality =>
          'Each morning at your alarm I can give you a short digest. Who should give it: a productivity advisor, a personal coach, a Socratic tutor, or someone else?',
        InterviewStep.confirm => typed
            ? 'You chose ${proactive ? 'proactive advice' : 'to wait until you write to me'}, '
                'and ${personalityId ?? ''} for your digest. Is that right?'
            : 'You chose ${proactive ? 'proactive advice' : 'to wait until you speak to me'}, '
                'the wake word ${keyword?.word ?? ''}, and ${personalityId ?? ''} for your digest. Is that right?',
        InterviewStep.done => typed
            ? 'All set. Type a message whenever you need me.'
            : 'All set. Say your wake word whenever you need me.',
      };
}

/// Wake keyword stored when the typed interview skips its step (voice
/// off). The digest profile needs one; it is the app's name, and it applies
/// only if voice is switched on later.
const typedDefaultKeyword = 'illunis';

/// Applies [answer] to [state]. An answer of the wrong kind for the current
/// step leaves the state unchanged. [typed] (voice off) skips the wake
/// keyword step and keeps [typedDefaultKeyword] (or a keyword already set).
InterviewState advance(InterviewState state, InterviewAnswer answer, {bool typed = false}) {
  switch ((state.step, answer)) {
    case (InterviewStep.greet, Acknowledge()):
      return state._copy(step: InterviewStep.askProactive);

    case (InterviewStep.askProactive, ProactiveAnswer(:final mode)):
      return state._copy(
        step: typed ? InterviewStep.askDigestPersonality : InterviewStep.askWakeKeyword,
        proactive: mode == ProactiveMode.proactive,
        keyword: typed ? (state.keyword ?? WakeKeyword.tryCreate(typedDefaultKeyword)) : null,
      );

    case (InterviewStep.askWakeKeyword, KeywordAnswer(:final keyword)):
      final rejection = validateKeyword(keyword);
      if (rejection != null) return state._copy(keywordRejection: rejection);
      return state._copy(
        step: InterviewStep.askDigestPersonality,
        keyword: WakeKeyword.tryCreate(keyword),
      );

    case (InterviewStep.askDigestPersonality, PersonalityAnswer(:final personalityId, :final skillPackId)):
      if (personalityId.trim().isEmpty) return state;
      return state._copy(
        step: InterviewStep.confirm,
        personalityId: personalityId.trim(),
        skillPackId: skillPackId,
      );

    case (InterviewStep.confirm, ConfirmAnswer(:final yes)):
      // "No" restarts the questions; proactive returns to its default (off).
      return yes
          ? state._copy(step: InterviewStep.done)
          : const InterviewState(step: InterviewStep.askProactive);

    default:
      return state;
  }
}
