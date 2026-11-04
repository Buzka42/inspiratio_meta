/// First-run interview spoken through [TtsPort], then the alarm digest,
/// spoken through [SpeechOutput] (sentence-chunked and cancellable).
/// With a [StateStore], the interview step and answers and the last digest
/// date survive restarts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../output/speech_output.dart';
import '../output/tts_engine.dart';
import '../voice/alarm_digest.dart';
import '../voice/morning_interview.dart';
import '../voice/wake_keyword.dart';
import 'council_flow.dart';
import 'persistence.dart';
import 'server_port.dart';
import 'tts_port.dart';

/// What the interview settles. Used to program the digest.
class DigestProfile {
  const DigestProfile({
    required this.proactive,
    required this.keyword,
    required this.personalityId,
    this.skillPackId,
  });
  final bool proactive;
  final String keyword;
  final String personalityId;
  final String? skillPackId;
}

class MorningFlow {
  MorningFlow({
    required this.tts,
    required this.server,
    this.alarm,
    this.profile,
    this.store,
    SpeechOutput? speech,
  }) : speech = speech ?? SpeechOutput(TtsPortEngine(tts));

  /// Interview prompts.
  final TtsPort tts;
  final ServerPort server;

  /// Digest speech. Share the [AppController]'s instance (the
  /// [AlarmCoordinator] does) so a barge-in cancels the digest; a private
  /// instance cannot be interrupted by the controller.
  SpeechOutput speech;

  /// Null keeps everything in memory (a restart forgets it).
  final StateStore? store;

  /// Local wall-clock alarm, or null when none is set.
  LocalTime? alarm;
  DigestProfile? profile;

  /// Runs after a digest that played to the end (the mood, energy and sleep
  /// check-in question). A failure is logged by type only.
  Future<void> Function()? afterDigest;

  /// The short-term context for the server's digest council run.
  CouncilContext Function()? councilContext;

  /// Speaks the digest's council answer (and shows its sources). Null speaks
  /// it through [speech] without captions.
  CouncilSpeaker? councilSpeaker;

  /// Runs after the digest and its council answer, before [afterDigest]:
  /// the assistant inbox items folded in, then the weekly 21-day analysis.
  /// False (the user interrupted) skips the rest. A failure is logged.
  Future<bool> Function()? digestExtras;

  Future<bool> _extras() async {
    try {
      return await digestExtras?.call() ?? true;
    } catch (e) {
      debugPrint('digest: extras_failed error=${e.runtimeType}');
      return true;
    }
  }

  Future<void> _followUp() async {
    try {
      await afterDigest?.call();
    } catch (e) {
      debugPrint('digest: follow_up_failed error=${e.runtimeType}');
    }
  }

  /// Date the digest last fired. Persisted when [store] is set, so a restart
  /// does not replay a digest that already played today.
  LocalDate? lastFired;
  bool _firing = false;

  InterviewState _state = const InterviewState();
  InterviewState get interview => _state;
  bool get interviewDone => _state.step == InterviewStep.done;

  /// Restores the interview and the last digest date from [store]. Missing or
  /// unreadable data leaves the defaults (interview from the greeting).
  Future<void> load() async {
    final s = store;
    if (s == null) return;
    lastFired = decodeDate(await s.getString(StoreKeys.digestLastFired));
    final restored = decodeInterview(await s.getString(StoreKeys.interview));
    if (restored != null) {
      _state = restored;
      _setProfileIfDone();
    }
  }

  void _setProfileIfDone() {
    if (!interviewDone) return;
    profile = DigestProfile(
      proactive: _state.proactive,
      // A typed interview skips the keyword step; use the typed default.
      keyword: _state.keyword?.word ?? typedDefaultKeyword,
      personalityId: _state.personalityId!,
      skillPackId: _state.skillPackId,
    );
  }

  /// Speaks the current prompt (the greeting on first run).
  Future<void> start() => tts.speak(_state.prompt);

  /// Applies an already parsed answer and speaks the next prompt. A wrong
  /// kind of answer repeats the current prompt.
  Future<void> answer(InterviewAnswer a) async {
    _state = advance(_state, a);
    _setProfileIfDone();
    await store?.setString(StoreKeys.interview, encodeInterview(_state));
    await tts.speak(_state.prompt);
  }

  /// Replaces the interview state and saves it, without speaking. Used by
  /// VoiceSetup, which parses spoken answers, runs [advance] itself and
  /// speaks its own prompts.
  Future<void> setInterview(InterviewState s) async {
    _state = s;
    _setProfileIfDone();
    await store?.setString(StoreKeys.interview, encodeInterview(_state));
  }

  /// Fires the digest when [shouldFireDigest] allows it and a profile and
  /// alarm exist. Returns the digest, or null when nothing fired.
  Future<DigestResult?> tick({
    required LocalTime now,
    required LocalDate today,
    List<Finding> findings = const [],
  }) async {
    final a = alarm, p = profile;
    if (a == null || p == null) return null;
    if (_firing) return null;
    if (!shouldFireDigest(alarm: a, now: now, today: today, lastFired: lastFired)) return null;
    _firing = true;
    final DigestResult d;
    try {
      // A failed call leaves lastFired unset, so a later tick retries.
      d = await server.digest(
          personalityId: p.personalityId,
          skillPackId: p.skillPackId,
          findings: findings,
          context: councilContext?.call());
    } finally {
      _firing = false;
    }
    lastFired = today;
    await store?.setString(StoreKeys.digestLastFired, encodeDate(today));
    // A cancelled digest (barge-in) stays fired and skips the rest: the
    // council answer, the disclaimer, the extras and the follow-up question.
    // The disclaimer is not repeated when the council answer already said it.
    if (!await _speak(d.text)) return d;
    final council = d.council;
    if (council != null) {
      final cs = councilSpeaker ?? CouncilSpeaker(speak: _speak);
      if (!await cs.say(council)) return d;
    }
    final disclaimer = d.disclaimer;
    final said = disclaimer != null &&
        council != null &&
        withMedicalLine(council.synthesis, council.medical).contains(disclaimer);
    if (disclaimer != null && !said && !await _speak(disclaimer)) return d;
    if (await _extras()) await _followUp();
    return d;
  }

  /// True when every sentence played; false on cancel or failure.
  Future<bool> _speak(String text) async {
    PlaybackEvent? last;
    await for (final e in speech.speak(text)) {
      last = e;
    }
    return last is PlaybackFinished;
  }
}

String encodeDate(LocalDate d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Null for null or malformed input.
LocalDate? decodeDate(String? s) {
  final m = s == null ? null : _dateRe.firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return LocalDate(y, mo, d);
}

/// Step and answers only; a pending keyword rejection is not kept.
String encodeInterview(InterviewState s) => jsonEncode({
      'step': s.step.name,
      'proactive': s.proactive,
      'keyword': ?s.keyword?.word,
      'personality_id': ?s.personalityId,
      'skill_pack_id': ?s.skillPackId,
    });

/// Null for null, malformed or inconsistent input (for example a later step
/// without the answer it depends on), so the interview starts over.
InterviewState? decodeInterview(String? raw) {
  if (raw == null) return null;
  final Object? j;
  try {
    j = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (j is! Map<String, dynamic>) return null;
  final step = InterviewStep.values.asNameMap()[j['step']];
  if (step == null) return null;
  final proactive = j['proactive'] == true;
  final kw = j['keyword'];
  final keyword = kw is String ? WakeKeyword.tryCreate(kw) : null;
  final pid = j['personality_id'];
  final personalityId = pid is String && pid.trim().isNotEmpty ? pid : null;
  final sp = j['skill_pack_id'];
  final skillPackId = sp is String ? sp : null;
  final needsKeyword = step.index > InterviewStep.askWakeKeyword.index;
  final needsPersonality = step.index > InterviewStep.askDigestPersonality.index;
  if ((needsKeyword && keyword == null) || (needsPersonality && personalityId == null)) {
    return null;
  }
  return InterviewState(
    step: step,
    proactive: proactive,
    keyword: keyword,
    personalityId: personalityId,
    skillPackId: skillPackId,
  );
}
