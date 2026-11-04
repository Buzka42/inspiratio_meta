/// Typed breathwork onboarding and the steps before a session (build plan
/// B7, decisions 2026-10-28 and 2026-10-28b, plan E6).
///
/// [BreathFlow] is a pure step machine the breath view renders. Every step
/// is one Yes / No question (tapped, or typed as a plain yes or no) or a
/// typed choice; nothing moves on without an answer, and a session starts
/// only after a yes to "Start ... now?".
///
/// First run (no stored profile): what the sessions are for and not for, how
/// they work, the default screen question, then "Do you practise breathwork
/// at an advanced level?". The answer is stored and never inferred. A yes to
/// any screen question shows the clinician notice and the session does not
/// run. Screens answered no are stored, so they are asked once each.
/// Logs carry step codes only, never answers or text.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';
import 'breath_library.dart';
import 'technique.dart';

/// Store key for [BreathProfile] (the user's own onboarding answers).
const breathProfileKey = 'breath_profile';

/// The one question every screen asks; [screenItems] lists what it covers
/// (research section 4 and section 5's default screen), one short line per
/// condition. Phrased without diagnosing.
const screenQuestion = 'Do any of these apply to you?';

const screenItems = <ScreenKind, List<String>>{
  ScreenKind.standard: [
    'Epilepsy or seizures',
    'A heart or heart rhythm condition',
    'High blood pressure that is not under control',
    'Pregnancy',
    'Recent psychosis or mania',
    'Recent fainting linked to breathing',
  ],
  ScreenKind.holds: [
    'A lung or breathing condition',
    'High blood pressure',
    'A heart condition',
    'Pregnancy',
  ],
  ScreenKind.forceful: [
    'Epilepsy',
    'High blood pressure',
    'A heart condition',
    'Pregnancy',
    'Recent stomach surgery, a hernia or a stomach ulcer',
  ],
};

/// Used when no technique's own notice is at hand (research 6.5).
const defaultNotice = 'This is not medical advice. If you have a health condition or feel unwell, '
    'speak to a qualified clinician before you practise.';

const introText = 'A few quiet minutes with your breath. This is not medical advice and not a treatment '
    'for any condition.';
const howText = 'A ring of light grows as you breathe in and shrinks as you breathe out. Spoken cues are '
    'optional. Pause and Stop stay on screen. You can stop at any time.';
const advancedQuestion = 'Do you practise breathwork at an advanced level?';
const advancedBody = 'Advanced techniques are offered only if you answer yes.';

/// What a typed answer may be. Only a plain yes or no counts: on a health
/// screen, "not sure" must never read as no.
const _typedYes = {'yes', 'y', 'yeah', 'yep', 'yup', 'yes please'};
const _typedNo = {'no', 'n', 'nope', 'no thanks', 'no thank you'};

/// True for a typed yes, false for a typed no, null for anything else.
bool? typedYesNo(String raw) {
  final t = raw.toLowerCase().replaceAll(RegExp('[^a-z ]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');
  if (_typedYes.contains(t)) return true;
  if (_typedNo.contains(t)) return false;
  return null;
}

class BreathProfile {
  const BreathProfile({required this.advanced, this.cleared = const {}});

  /// Set by the user in onboarding. Never inferred.
  final bool advanced;

  /// Screens the user answered no to.
  final Set<ScreenKind> cleared;

  BreathProfile clear(ScreenKind s) => BreathProfile(advanced: advanced, cleared: {...cleared, s});

  String encode() => jsonEncode({'v': 1, 'advanced': advanced, 'cleared': [for (final s in cleared) s.name]});

  static BreathProfile? decode(String? s) {
    if (s == null) return null;
    try {
      final j = jsonDecode(s) as Map<String, Object?>;
      final advanced = j['advanced'];
      if (advanced is! bool) return null;
      final cleared = <ScreenKind>{
        for (final n in (j['cleared'] as List<Object?>? ?? const []))
          ?ScreenKind.values.where((k) => k.name == n).firstOrNull,
      };
      return BreathProfile(advanced: advanced, cleared: cleared);
    } on Object {
      return null; // a damaged record means onboarding runs again
    }
  }
}

class BreathProfileStore {
  BreathProfileStore(this.store);
  final StateStore store;

  Future<BreathProfile?> load() async => BreathProfile.decode(await store.getString(breathProfileKey));
  Future<void> save(BreathProfile p) => store.setString(breathProfileKey, p.encode());
}

/// What the view shows.
sealed class BreathStep {
  const BreathStep();
}

/// Loading the stored profile.
class BreathLoading extends BreathStep {
  const BreathLoading();
}

enum AskKind { intro, how, screen, advanced, start }

/// A Yes / No question, answered by a tap or a typed yes or no. [body] is
/// shown above [question], [items] under it (a screen's conditions).
class BreathAsk extends BreathStep {
  const BreathAsk(this.kind, this.question, {this.body, this.screen, this.items = const [], this.miss = false});
  final AskKind kind;
  final String question;
  final String? body;
  final ScreenKind? screen;
  final List<String> items;

  /// The last typed answer was neither yes nor no.
  final bool miss;

  BreathAsk missed() => BreathAsk(kind, question, body: body, screen: screen, items: items, miss: true);
}

/// The user types (or taps) a technique name. [listed] is non-null only
/// after the user asked to see the list.
class BreathChoose extends BreathStep {
  const BreathChoose({this.listed, this.miss = false});
  final List<Technique>? listed;

  /// The last typed name matched nothing.
  final bool miss;
}

/// A message and no session (declined, a screen yes, refused technique).
class BreathNotice extends BreathStep {
  const BreathNotice(this.text, {this.notice});
  final String text;

  /// The clinician notice, when one applies.
  final String? notice;
}

/// Everything answered: the session may start.
class BreathReady extends BreathStep {
  const BreathReady(this.technique);
  final Technique technique;
}

class BreathFlow extends ChangeNotifier {
  BreathFlow({
    required this.library,
    required this.profiles,
    Technique? requested,
    void Function(String line)? log,
  })  : _technique = requested,
        _log = log ?? debugPrint;

  final BreathLibrary library;
  final BreathProfileStore profiles;
  final void Function(String line) _log;

  BreathStep _step = const BreathLoading();
  BreathStep get step => _step;

  BreathProfile? _profile;
  BreathProfile? get profile => _profile;
  Technique? _technique;
  bool _onboarding = false;

  Future<void> start() async {
    _profile = await profiles.load();
    if (_profile == null) {
      _onboarding = true;
      _go(const BreathAsk(AskKind.intro, 'Continue?', body: introText));
    } else {
      _afterOnboarding();
    }
  }

  /// A tapped or typed yes / no for the current [BreathAsk].
  Future<void> answer(bool yes) async {
    final s = _step;
    if (s is! BreathAsk) return;
    switch (s.kind) {
      case AskKind.intro:
        yes ? _go(const BreathAsk(AskKind.how, 'Continue?', body: howText)) : _declined();
      case AskKind.how:
        yes ? _go(_screenAsk(ScreenKind.standard)) : _declined();
      case AskKind.screen:
        if (yes) {
          _log('breath: screen_yes');
          _go(BreathNotice('This session will not start.', notice: _technique?.copy.notice ?? defaultNotice));
          return;
        }
        if (_onboarding) {
          _pendingCleared.add(s.screen!);
          _go(const BreathAsk(AskKind.advanced, advancedQuestion, body: advancedBody));
          return;
        }
        _profile = _profile!.clear(s.screen!);
        await profiles.save(_profile!);
        _nextScreenOrStart();
      case AskKind.advanced:
        _profile = BreathProfile(advanced: yes, cleared: _pendingCleared);
        _onboarding = false;
        await profiles.save(_profile!);
        _log('breath: onboarding_done');
        _afterOnboarding();
      case AskKind.start:
        if (!yes) {
          _declined();
          return;
        }
        _log('breath: ready');
        _go(BreathReady(_technique!));
    }
  }

  final _pendingCleared = <ScreenKind>{};

  /// A typed answer to the current [BreathAsk]: a plain yes or no answers
  /// it like a tap; anything else keeps the question and says so.
  Future<void> answerTyped(String typed) async {
    final s = _step;
    if (s is! BreathAsk) return;
    final yes = typedYesNo(typed);
    if (yes == null) {
      _go(s.missed());
      return;
    }
    await answer(yes);
  }

  /// A typed technique name (or a tapped list entry's name).
  void choose(String typed) {
    if (_step is! BreathChoose) return;
    final t = library.match(typed);
    if (t == null) {
      _go(BreathChoose(listed: (_step as BreathChoose).listed, miss: true));
      return;
    }
    _technique = t;
    _resolve();
  }

  /// The user asked to see the list (basics in progression order; advanced
  /// ones only for an advanced practitioner).
  void showList() {
    if (_step is! BreathChoose) return;
    _go(BreathChoose(listed: library.listFor(advanced: _profile?.advanced ?? false)));
  }

  void _afterOnboarding() => _technique == null ? _go(const BreathChoose()) : _resolve();

  void _resolve() {
    final t = _technique!;
    switch (library.refusal(t, advanced: _profile!.advanced)) {
      case BreathRefusal.referenceOnly:
        _go(BreathNotice('${t.copy.intent} ${t.copy.end}', notice: t.copy.notice));
      case BreathRefusal.advancedOnly:
        _go(BreathNotice('${t.name} is an advanced technique. It is offered only if you answered in setup that you '
            'practise breathwork at an advanced level.'));
      case BreathRefusal.unavailable:
        _go(BreathNotice('${t.name} is in the library, but it cannot be guided in this app.',
            notice: t.copy.notice));
      case null:
        _nextScreenOrStart();
    }
  }

  void _nextScreenOrStart() {
    final t = _technique!;
    for (final s in t.screens) {
      if (screenItems.containsKey(s) &&!_profile!.cleared.contains(s)) {
        _go(_screenAsk(s));
        return;
      }
    }
    final minutes = (t.durationS / 60).round();
    _go(BreathAsk(AskKind.start, 'Start ${t.name} now?',
        body: '${t.copy.intent} It lasts about $minutes minute${minutes == 1 ? '' : 's'}.'));
  }

  BreathAsk _screenAsk(ScreenKind s) =>
      BreathAsk(AskKind.screen, screenQuestion, screen: s, items: screenItems[s]!);

  void _declined() => _go(const BreathNotice('No session started. Ask for breathwork whenever you like.'));

  void _go(BreathStep s) {
    _step = s;
    notifyListeners();
  }
}
