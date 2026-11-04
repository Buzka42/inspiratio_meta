// The composer's Enter key sends (phone bug 2026-11-04: Enter added a new
// line because the 4-line field asked for the multiline keyboard).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/widgets/chat_composer.dart';

Future<List<String>> pumpComposer(WidgetTester t) async {
  final sent = <String>[];
  final thread = ChatThread();
  addTearDown(thread.dispose);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: ChatComposer(thread: thread, onSubmit: sent.add))));
  await t.pump();
  return sent;
}

/// The input configuration last sent to the platform keyboard.
Map<String, dynamic> lastClientConfig(WidgetTester t) {
  final call = t.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient');
  return (call.arguments as List)[1] as Map<String, dynamic>;
}

void main() {
  testWidgets('the keyboard gets a text input with the send action, not multiline', (t) async {
    await pumpComposer(t);
    final field = t.widget<EditableText>(find.descendant(of: find.byKey(ChatComposer.fieldKey), matching: find.byType(EditableText)));
    expect(field.textInputAction, TextInputAction.send);
    expect(field.keyboardType, TextInputType.text);
    await t.showKeyboard(find.byKey(ChatComposer.fieldKey));
    final config = lastClientConfig(t);
    expect(config['inputAction'], 'TextInputAction.send');
    expect((config['inputType'] as Map)['name'], 'TextInputType.text');
  });

  testWidgets('Enter (the send action) calls onSubmit once and clears the field', (t) async {
    final sent = await pumpComposer(t);
    await t.enterText(find.byKey(ChatComposer.fieldKey), '  Synthetic line ');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pump();
    expect(sent, ['Synthetic line']);
    expect(t.widget<TextField>(find.byKey(ChatComposer.fieldKey)).controller!.text, isEmpty);
  });
}
