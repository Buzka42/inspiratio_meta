import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/voice/assistant_intent.dart';

// Synthetic names and texts only.
void main() {
  const msg = AssistantIntentKind.message, act = AssistantIntentKind.action;

  test('ask my assistant <question> is a message', () {
    expect(parseAssistantIntent('Ask my assistant what is on tomorrow.'),
        const AssistantIntent(msg, 'what is on tomorrow'));
    expect(parseAssistantIntent('hey, ask the assistant, when is the next session'),
        const AssistantIntent(msg, 'when is the next session'));
    expect(parseAssistantIntent('tell my assistant that I slept badly'),
        const AssistantIntent(msg, 'I slept badly'));
  });

  test('ask or tell my assistant to ... is an action', () {
    expect(parseAssistantIntent('Ask my assistant to message Ana that I am late'),
        const AssistantIntent(act, 'message Ana that I am late'));
    expect(parseAssistantIntent('please tell my assistant to remind Leo about the call'),
        const AssistantIntent(act, 'remind Leo about the call'));
  });

  test('tell my <name> bot and message my <name> are actions with the whole sentence', () {
    expect(parseAssistantIntent('Tell my coach bot I will be late'),
        const AssistantIntent(act, 'Tell my coach bot I will be late'));
    expect(parseAssistantIntent('message my sister that dinner is at seven'),
        const AssistantIntent(act, 'message my sister that dinner is at seven'));
  });

  test('other sentences are not assistant intents', () {
    for (final t in [
      'tell me a story',
      'ask my doctor whether I should fast',
      'my assistant is great',
      'ask my assistant',
      'tell my assistant hi',
      'what is on tomorrow',
      '',
    ]) {
      expect(parseAssistantIntent(t), isNull, reason: t);
    }
  });
}
