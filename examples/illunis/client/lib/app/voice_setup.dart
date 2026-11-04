/// Voice-only setup: the morning interview answered by speaking, and spoken
/// changes afterwards ("change my alarm to 6:45"). There is no settings
/// screen.
///
/// Transcripts arrive through [AppController.setupHook] (wired to [claim]),
/// so they come from the SpeechToTextPort session the input pipeline opens.
/// Each is parsed for the current step (lib/voice/setup_answers.dart); an
/// unreadable answer re-asks the same step with a short fixed prompt.
///
/// The interview state machine (voice/morning_interview.dart) is unchanged.
/// It asks for the personality and its skill pack in one answer and has no
/// alarm step, so this layer splits that step in two and adds the alarm time
/// before the confirmation. Those in-between answers are a draft saved under
/// [StoreKeys.voiceSetup], so an interrupted interview resumes at the same
/// step. On "yes" the alarm (time, personality, skill pack) is saved through
/// [saveAlarm], the interview (proactive flag, wake keyword) through
/// [MorningFlow.setInterview], and [onKeywordChanged] restarts spotting.
///
/// With [VoiceSetup.typed] (voice off, core/voice_flags.dart) the same
/// interview is answered by typing: the wake keyword step is skipped (the
/// interview keeps [typedDefaultKeyword]), "change my wake word" is not
/// taken, and prompts say "type" instead of "say".
///
/// Logs carry codes only, never a transcript or a saved value.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../alarm/alarm_settings.dart';
import '../voice/alarm_digest.dart';
import '../voice/morning_interview.dart';
import '../voice/setup_answers.dart';
import '../voice/setup_intent.dart';
import '../voice/wake_keyword.dart';
import 'morning_flow.dart';
import 'persistence.dart';

typedef SetupLog = void Function(String line);

enum SetupStep { greet, proactive, keyword, personality, skillPack, alarmTime, confirm, done }

/// Fixed re-ask prompts, one per step.
abstract final class SetupReask {
  static const greet = 'Please say anything to begin.';
  static const proactive = 'Please say proactive, or wait.';
  static const keyword = 'Please say just one word.';
  static const personality = 'Please say one name, such as calm guide or personal coach.';
  static const skillPack = 'Please say one skill pack, such as breathwork, or say none.';
  static const alarmTime = 'Please say a time, such as seven thirty.';
  static const confirm = 'Please say yes or no.';
}

/// Typed re-ask prompts (voice off); the keyword step is never asked.
abstract final class TypedSetupReask {
  static const greet = 'Please type anything to begin.';
  static const proactive = 'Please type proactive, or wait.';
  static const personality = 'Please type one name, such as calm guide or personal coach.';
  static const skillPack = 'Please type one skill pack, such as breathwork, or type none.';
  static const alarmTime = 'Please type a time, such as 7:30.';
  static const confirm = 'Please type yes or no.';
}

const typedSkillPackPrompt = 'Would you like a skill pack with it: breathwork, habit building, '
    'meditation basics, motivation, weight training, or wind-down routine? Or type none.';
const typedAlarmTimePrompt = 'What time should your alarm ring? For example, 7:30.';

const skillPackPrompt = 'Would you like a skill pack with it: breathwork, habit building, '
    'meditation basics, motivation, weight training, or wind-down routine? Or say none.';
const alarmTimePrompt = 'What time should your alarm ring? For example, seven thirty.';

/// Answers between the interview steps; see the library comment.
class SetupDraft {
  const SetupDraft({this.personalityId, this.alarm, this.edit});

  /// Chosen personality while the skill pack is still to come.
  final String? personalityId;

  /// Alarm time chosen during the interview, before the confirmation.
  final LocalTime? alarm;

  /// A spoken change ("change my alarm") waiting for its value.
  final SetupTarget? edit;

  bool get isEmpty => personalityId == null && alarm == null && edit == null;

  String encode() => jsonEncode({
        'personality_id': ?personalityId,
        if (alarm != null) 'alarm': formatClock(alarm!),
        'edit': ?edit?.name,
      });

  /// Empty for null or malformed input; an unknown field value is dropped.
  static SetupDraft decode(String? raw, Set<String> personalityIds) {
    if (raw == null) return const SetupDraft();
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return const SetupDraft();
    }
    if (j is! Map<String, dynamic>) return const SetupDraft();
    final pid = j['personality_id'];
    final alarm = j['alarm'];
    final edit = j['edit'];
    return SetupDraft(
      personalityId: pid is String && personalityIds.contains(pid) ? pid : null,
      alarm: alarm is String ? parseClock(alarm) : null,
      edit: edit is String ? SetupTarget.values.asNameMap()[edit] : null,
    );
  }
}

class VoiceSetup {
  VoiceSetup({
    required this.flow,
    required this.alarmStore,
    Future<void> Function(AlarmSettings)? saveAlarm,
    StateStore? store,
    this.onKeywordChanged,
    this.listen,
    this.personalityIds = knownPersonalityIds,
    this.skillPackIds = knownSkillPackIds,
    this.typed = false,
    this.shownLast,
    SetupLog? log,
  })  : saveAlarm = saveAlarm ?? alarmStore.save,
        store = store ?? flow.store,
        _log = log ?? debugPrint;

  final MorningFlow flow;

  /// Read for the current alarm when only its time changes.
  final AlarmSettingsStore alarmStore;

  /// Saves (and in the app, schedules) the alarm. The app passes
  /// AlarmCoordinator.setAlarm, which saves through [alarmStore].
  final Future<void> Function(AlarmSettings) saveAlarm;

  /// Holds the draft. Defaults to the flow's store.
  final StateStore? store;

  /// Called after the wake keyword is set or changed (the input pipeline's
  /// refreshKeyword).
  final void Function()? onKeywordChanged;

  /// Opens a listening session after a prompt that expects an answer (the
  /// app dispatches WakeWordHeard when the microphone is running).
  final void Function()? listen;

  final Set<String> personalityIds;
  final Set<String> skillPackIds;

  /// Typed onboarding (voice off): see the library comment.
  final bool typed;

  /// True when the screen already ends with this prompt (typed chat: the
  /// thread restored after a restart). [start] then does not post it again.
  final bool Function(String prompt)? shownLast;
  final SetupLog _log;

  SetupDraft _draft = const SetupDraft();
  SetupDraft get draft => _draft;

  Future<void> _queue = Future.value();

  /// Completes when every claimed transcript has been handled.
  Future<void> get settled => _queue;

  /// Restores the draft. Call after [MorningFlow.load].
  Future<void> load() async {
    _draft = SetupDraft.decode(await store?.getString(StoreKeys.voiceSetup), personalityIds);
  }

  SetupStep get step {
    final e = _draft.edit;
    if (e != null) return e == SetupTarget.alarm ? SetupStep.alarmTime : SetupStep.keyword;
    return switch (flow.interview.step) {
      InterviewStep.greet => SetupStep.greet,
      InterviewStep.askProactive => SetupStep.proactive,
      InterviewStep.askWakeKeyword => SetupStep.keyword,
      InterviewStep.askDigestPersonality =>
        _draft.personalityId == null ? SetupStep.personality : SetupStep.skillPack,
      InterviewStep.confirm => _draft.alarm == null ? SetupStep.alarmTime : SetupStep.confirm,
      InterviewStep.done => SetupStep.done,
    };
  }

  /// True while the interview or a spoken change waits for an answer.
  bool get active => step != SetupStep.done;

  /// What Illunis asks at the current step.
  String get prompt => switch (step) {
        SetupStep.skillPack => typed ? typedSkillPackPrompt : skillPackPrompt,
        SetupStep.alarmTime => typed ? typedAlarmTimePrompt : alarmTimePrompt,
        SetupStep.confirm => _confirmPrompt(),
        SetupStep.keyword when _draft.edit != null =>
          const InterviewState(step: InterviewStep.askWakeKeyword).prompt,
        _ => flow.interview.promptFor(typed: typed),
      };

  String _confirmPrompt() {
    final s = flow.interview;
    final skill = s.skillPackId;
    final wait = typed ? 'to wait until you write to me' : 'to wait until you speak to me';
    return 'You chose ${s.proactive ? 'proactive advice' : wait}, '
        '${typed ? '' : 'the wake word ${s.keyword?.word ?? ''}, '}'
        'the ${spokenName(s.personalityId ?? '')} for your digest '
        '${skill == null ? 'with no skill pack' : 'with ${spokenName(skill)}'}, '
        'and an alarm at ${formatClock(_draft.alarm!)}. Is that right?';
  }

  /// Speaks the current prompt and listens, when setup is under way (the
  /// greeting on first run, the saved step after a restart).
  Future<void> start() async {
    // A voice interview saved at the keyword step continues typed past it.
    if (typed && _draft.edit == null && flow.interview.step == InterviewStep.askWakeKeyword) {
      await flow.setInterview(advance(flow.interview, const KeywordAnswer(typedDefaultKeyword)));
    }
    if (!active) return;
    if (shownLast?.call(prompt) ?? false) return;
    await _ask(prompt);
  }

  /// For [AppController.onSilence]: a listening turn ended with no speech, so
  /// the current question is asked again (and the microphone reopens).
  void heardNothing() {
    if (!active) return;
    _queue = _queue.then((_) => _ask(prompt));
  }

  /// For [AppController.setupHook]: takes every transcript while [active],
  /// and otherwise only a setup intent. Handling runs in order, after the
  /// voice turn has ended.
  bool claim(String text) {
    if (!active && _intent(text) == null) return false;
    _queue = _queue.then((_) => _guarded(text));
    return true;
  }

  /// Handles one transcript now. Prefer [claim] in the app.
  Future<void> hear(String text) => _guarded(text);

  /// A setup intent; typed setup has no wake word to change.
  SetupIntent? _intent(String text) {
    final i = parseSetupIntent(text);
    return typed && i?.target == SetupTarget.wakeKeyword ? null : i;
  }

  Future<void> _guarded(String text) async {
    try {
      await _handle(text);
    } catch (e) {
      _log('setup: failed error=${e.runtimeType}');
    }
  }

  Future<void> _handle(String text) async {
    final at = step;
    if (at == SetupStep.done || (at == SetupStep.confirm && _draft.edit == null)) {
      final intent = _intent(text);
      if (intent != null) return _beginEdit(intent);
      if (at == SetupStep.done) return;
    }
    if (_draft.edit != null) return _answerEdit(text);
    final s = flow.interview;
    switch (at) {
      case SetupStep.greet:
        final a = parseAcknowledge(text);
        if (a == null) return _reask(at, typed ? TypedSetupReask.greet : SetupReask.greet);
        return _advance(advance(s, a));
      case SetupStep.proactive:
        final a = parseProactive(text);
        if (a == null) return _reask(at, typed ? TypedSetupReask.proactive : SetupReask.proactive);
        return _advance(advance(s, a, typed: typed));
      case SetupStep.keyword:
        final a = parseKeyword(text);
        if (a == null) return _reask(at, SetupReask.keyword);
        // A rejected word stays on this step with the machine's reason.
        final next = advance(s, a);
        await _advance(next);
        if (next.keyword != null && next.step != s.step) onKeywordChanged?.call();
      case SetupStep.personality:
        final id = parsePersonality(text, personalityIds);
        if (id == null) return _reask(at, typed ? TypedSetupReask.personality : SetupReask.personality);
        await _saveDraft(SetupDraft(personalityId: id, alarm: _draft.alarm));
        return _ask(prompt);
      case SetupStep.skillPack:
        final c = parseSkillPack(text, skillPackIds);
        if (c == null) return _reask(at, typed ? TypedSetupReask.skillPack : SetupReask.skillPack);
        final next = advance(s, PersonalityAnswer(_draft.personalityId!, skillPackId: c.id));
        await flow.setInterview(next);
        await _saveDraft(SetupDraft(alarm: _draft.alarm));
        return _ask(prompt);
      case SetupStep.alarmTime:
        final t = parseAlarmTime(text);
        if (t == null) return _reask(at, typed ? TypedSetupReask.alarmTime : SetupReask.alarmTime);
        await _saveDraft(SetupDraft(alarm: t));
        return _ask(prompt);
      case SetupStep.confirm:
        final a = parseConfirm(text);
        if (a == null) return _reask(at, typed ? TypedSetupReask.confirm : SetupReask.confirm);
        if (a.yes) return _finish();
        // "No" restarts the questions (the machine's rule); the draft goes too.
        await flow.setInterview(advance(s, a));
        await _saveDraft(const SetupDraft());
        return _ask(prompt);
      case SetupStep.done:
        return;
    }
  }

  /// Saves the alarm first, then marks the interview done, so an
  /// interruption in between resumes at the confirmation and saves again.
  Future<void> _finish() async {
    final s = flow.interview;
    final t = _draft.alarm!;
    final settings = AlarmSettings.validate(
        hour: t.hour,
        minute: t.minute,
        personalityId: s.personalityId,
        skillPackId: s.skillPackId,
        log: _log);
    if (settings == null) {
      await _saveDraft(const SetupDraft());
      return _ask(prompt); // Back to the alarm time.
    }
    await saveAlarm(settings);
    await flow.setInterview(advance(s, const ConfirmAnswer(true)));
    await _saveDraft(const SetupDraft());
    onKeywordChanged?.call();
    _log('setup: saved');
    await flow.tts.speak(flow.interview.promptFor(typed: typed));
  }

  Future<void> _beginEdit(SetupIntent intent) async {
    await _saveDraft(SetupDraft(alarm: _draft.alarm, edit: intent.target));
    final v = intent.value;
    if (v == null) return _ask(prompt);
    return _answerEdit(v);
  }

  Future<void> _answerEdit(String text) async {
    final s = flow.interview;
    final inInterview = s.step != InterviewStep.done;
    switch (_draft.edit!) {
      case SetupTarget.alarm:
        final t = parseAlarmTime(text);
        if (t == null) {
          return _reask(SetupStep.alarmTime, typed ? TypedSetupReask.alarmTime : SetupReask.alarmTime);
        }
        if (inInterview) {
          await _saveDraft(SetupDraft(alarm: t));
          return _ask(prompt);
        }
        final current = await alarmStore.load();
        final p = flow.profile;
        final settings = AlarmSettings.validate(
            hour: t.hour,
            minute: t.minute,
            personalityId: current?.personalityId ?? p?.personalityId,
            skillPackId: current != null ? current.skillPackId : p?.skillPackId,
            log: _log);
        if (settings == null) {
          return _reask(SetupStep.alarmTime, typed ? TypedSetupReask.alarmTime : SetupReask.alarmTime);
        }
        await saveAlarm(settings);
        await _saveDraft(const SetupDraft());
        _log('setup: alarm_changed');
        await flow.tts.speak('Your alarm is set for ${formatClock(t)}.');
      case SetupTarget.wakeKeyword:
        final a = parseKeyword(text);
        if (a == null) return _reask(SetupStep.keyword, SetupReask.keyword);
        final rejection = validateKeyword(a.keyword);
        if (rejection != null) {
          _log('setup: keyword_rejected code=${rejection.name}');
          return _ask(InterviewState(step: InterviewStep.askWakeKeyword, keywordRejection: rejection)
              .prompt);
        }
        final kw = WakeKeyword.tryCreate(a.keyword)!;
        await flow.setInterview(InterviewState(
          step: s.step,
          proactive: s.proactive,
          keyword: kw,
          personalityId: s.personalityId,
          skillPackId: s.skillPackId,
        ));
        await _saveDraft(SetupDraft(alarm: _draft.alarm));
        onKeywordChanged?.call();
        _log('setup: keyword_changed');
        if (inInterview) return _ask(prompt);
        await flow.tts.speak('Your wake word is now ${kw.word}.');
    }
  }

  Future<void> _advance(InterviewState next) async {
    await flow.setInterview(next);
    return _ask(prompt);
  }

  Future<void> _reask(SetupStep at, String text) {
    _log('setup: reask step=${at.name}');
    return _ask(text);
  }

  Future<void> _ask(String text) async {
    await flow.tts.speak(text);
    if (active) listen?.call();
  }

  Future<void> _saveDraft(SetupDraft d) async {
    _draft = d;
    final s = store;
    if (s == null) return;
    if (d.isEmpty) {
      await s.remove(StoreKeys.voiceSetup);
    } else {
      await s.setString(StoreKeys.voiceSetup, d.encode());
    }
  }
}
