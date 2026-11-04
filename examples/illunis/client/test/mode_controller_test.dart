import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/core/mode_controller.dart';

void main() {
  test('default is reflection', () {
    expect(ModeController().mode, GraphicMode.reflection);
  });
  test('parses the two voice intents', () {
    expect(parseModeIntent('Show me the sky'), GraphicMode.classic);
    expect(parseModeIntent('hey, show me the sky!'), GraphicMode.classic);
    expect(parseModeIntent('show the water'), GraphicMode.reflection);
    expect(parseModeIntent('Show the water.'), GraphicMode.reflection);
  });
  test('unrelated speech is not an intent', () {
    expect(parseModeIntent('what is the weather'), isNull);
    expect(parseModeIntent(''), isNull);
  });
  test('handleUtterance switches mode and notifies once', () {
    final c = ModeController();
    final seen = <GraphicMode>[];
    c.addListener(seen.add);
    expect(c.handleUtterance('show me the sky'), isTrue);
    expect(c.handleUtterance('show me the sky'), isTrue);
    expect(c.mode, GraphicMode.classic);
    expect(c.handleUtterance('hello'), isFalse);
    expect(c.handleUtterance('show the water'), isTrue);
    expect(seen, [GraphicMode.classic, GraphicMode.reflection]);
  });
}
