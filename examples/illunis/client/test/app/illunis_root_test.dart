import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/app_controller.dart';
import 'package:illunis_client/app/illunis_root.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/sky_bake.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/captions/caption_style.dart';
import 'package:illunis_client/captions/caption_timing.dart';
import 'package:illunis_client/captions/caption_view.dart';
import 'package:illunis_client/core/fog_settings.dart';
import 'package:illunis_client/widgets/water_pass.dart';

void main() {
  testWidgets('Reflection by default, Classic after an utterance, captions with fog on or off',
      (t) async {
    final c = AppController(
        fog: FogSettings(InMemoryKeyValueStore()), server: FakeServerPort(), tts: SilentTts());
    await t.pumpWidget(IllunisRoot(
      controller: c,
      waterProgramLoader: () => Future.error(StateError('no shader in tests')),
      now: DateTime.utc(2026, 6, 21, 0),
      loadSkyShader: false,
      bakeConfig: const SkyBakeConfig(equirectWidth: 128, focal: 24),
    ));
    await t.pump();
    expect(find.byType(WaterPass), findsOneWidget);
    expect(find.byType(CaptionView), findsNothing);
    expect(find.byType(Text), findsNothing); // no visible UI beyond the sky
    expect(find.byType(Slider), findsNothing);

    c.handleUtterance('show me the sky');
    await t.pump();
    expect(find.byKey(const ValueKey('classic-sky')), findsOneWidget);
    expect(find.byType(WaterPass), findsNothing);

    c.say('Synthetic caption.');
    await t.pump();
    expect(find.text('Synthetic caption.'), findsOneWidget);
    // Centred on the sky; pale ink on the midnight sky.
    final screen = t.getRect(find.byType(IllunisRoot)).center;
    final text = t.getRect(find.text('Synthetic caption.')).center;
    expect((text - screen).distance, lessThan(3));
    final view = t.widget<CaptionView>(find.byType(CaptionView));
    expect(view.ink, CaptionInk.pale);
    expect(view.fog, isTrue);

    // Fog off (docs/SKY.md section 7): the caption stays, static, and
    // leaves with a plain fade instead of the dissolve.
    await c.setFog(false);
    await t.pump();
    expect(find.text('Synthetic caption.'), findsOneWidget);
    expect(t.widget<CaptionView>(find.byType(CaptionView)).fog, isFalse);
    expect(t.state<CaptionViewState>(find.byType(CaptionView)).exitMode, isNot(CaptionExit.dissolve));
  });
}
