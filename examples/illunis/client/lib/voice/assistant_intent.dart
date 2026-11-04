/// Voice intents for the connected assistant (the Hermes `illunis` bot,
/// docs/DESIGN.md): "ask my assistant ..." sends a
/// message and speaks the answer; "tell my coach bot ..." or "ask my
/// assistant to ..." asks the assistant to act, which always goes through
/// the spoken approval flow. Pure, no I/O.
library;

enum AssistantIntentKind {
  /// POST /assistant/message with [AssistantIntent.text].
  message,

  /// POST /assistant/action/propose with [AssistantIntent.text] as the
  /// plain-words request.
  action,
}

class AssistantIntent {
  const AssistantIntent(this.kind, this.text);
  final AssistantIntentKind kind;
  final String text;

  @override
  bool operator ==(Object other) => other is AssistantIntent && other.kind == kind && other.text == text;
  @override
  int get hashCode => Object.hash(kind, text);
  @override
  String toString() => 'AssistantIntent(${kind.name})';
}

const _assistantNames = r'(?:assistant|hermes)';
const _lead = r'^(?:(?:hey|ok|okay|so|and|now|please|could you|can you|would you)[ ,]+)*';

final _askTo = RegExp('$_lead(?:ask|tell|get) (?:my|the) $_assistantNames[ ,:]+to (.+)\$', caseSensitive: false);
final _ask = RegExp('$_lead(?:ask|tell) (?:my|the) $_assistantNames[ ,:]+(?:that )?(.+)\$', caseSensitive: false);
/// "tell my coach bot ..." or "ask my `name` bot ...": the target must be
/// called a bot. "message my `name` ..." / "text ..." / "ping ...": any
/// name, since those verbs only ever mean sending a message.
final _botAction = RegExp('$_lead(?:ask|tell) my ([a-z][a-z0-9_-]*) bot[ ,:]+(.+)\$', caseSensitive: false);
final _sendAction = RegExp('$_lead(?:message|text|ping) my ([a-z][a-z0-9_-]*(?: bot)?)[ ,:]+(.+)\$',
    caseSensitive: false);

String _clean(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^[,:;\s]+|[\s]+$'), '');

/// The intent in [raw], or null.
///
/// - "ask my assistant to message Ana that I am late" -> action
/// - "ask my assistant what is on tomorrow" -> message "what is on tomorrow"
/// - "tell my assistant that I slept badly" -> message "I slept badly"
/// - "tell my coach bot I will be late" -> action (the whole sentence, so
///   the assistant sees the target and the text)
AssistantIntent? parseAssistantIntent(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'[.!]+$'), '');
  if (t.isEmpty) return null;
  final to = _askTo.firstMatch(t);
  if (to != null) return _intent(AssistantIntentKind.action, to[1]!);
  final ask = _ask.firstMatch(t);
  if (ask != null) return _intent(AssistantIntentKind.message, ask[1]!);
  if (_botAction.hasMatch(t) || _sendAction.hasMatch(t)) return _intent(AssistantIntentKind.action, t);
  return null;
}

AssistantIntent? _intent(AssistantIntentKind kind, String text) {
  final c = _clean(text);
  return c.split(' ').where((w) => w.isNotEmpty).length < 2 ? null : AssistantIntent(kind, c);
}
