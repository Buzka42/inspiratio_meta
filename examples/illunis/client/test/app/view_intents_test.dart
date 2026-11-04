import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/moon_focus.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/app/view_intents.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/core/mode_controller.dart';

void main() {
  test('mode phrases', () {
    expect(parseViewModeIntent('Classic mode.'), GraphicMode.classic);
    expect(parseViewModeIntent('switch to classic view'), GraphicMode.classic);
    expect(parseViewModeIntent('please switch to reflection mode'), GraphicMode.reflection);
    expect(parseViewModeIntent('use the water view'), GraphicMode.reflection);
    expect(parseViewModeIntent('show me the sky'), GraphicMode.classic); // existing phrase
    expect(parseViewModeIntent('show me the lake'), GraphicMode.reflection);
    expect(parseViewModeIntent('what is the classic mode of transport'), isNull);
    expect(parseViewModeIntent('zoom in on the moon'), isNull);
  });

  test('voice commands for the view never become server turns', () async {
    final focus = MoonFocus(maxZoom: 6);
    final modes = ViewModeController(focus: focus);
    final c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()),
        server: FakeServerPort(),
        tts: SilentTts(),
        modes: modes);
    final turns = <TurnRequest>[];
    c.turnRequests.listen(turns.add);

    expect(c.mode, GraphicMode.reflection); // default
    expect(c.handleUtterance('Zoom in on the moon'), UtteranceOutcome.modeChanged);
    expect(focus.zoom, closeTo(1.5, 1e-9));
    expect(c.mode, GraphicMode.reflection);

    expect(c.handleUtterance('classic mode'), UtteranceOutcome.modeChanged);
    expect(c.mode, GraphicMode.classic);
    expect(c.handleUtterance('switch to reflection mode'), UtteranceOutcome.modeChanged);
    expect(c.mode, GraphicMode.reflection);

    expect(c.handleUtterance('reset the moon'), UtteranceOutcome.modeChanged);
    expect(focus.zoom, 1);

    expect(c.handleUtterance('how did I sleep'), UtteranceOutcome.turnRequested);
    expect(turns.map((t) => t.text), ['how did I sleep']);
    await c.dispose();
  });

  test('pinch zoom is clamped to the focus range', () {
    final focus = MoonFocus(maxZoom: 6);
    var notes = 0;
    focus.addListener(() => notes++);
    focus.beginPinch();
    focus.updatePinch(3);
    expect(focus.zoom, 3);
    focus.updatePinch(100);
    expect(focus.zoom, 6);
    focus.updatePinch(0.01);
    expect(focus.zoom, 1);
    expect(notes, 3);
    expect(focus.angularRadius, closeTo(0.014, 1e-12));
  });
}
