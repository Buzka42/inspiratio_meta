import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/moon_manifest.dart';
import 'package:illunis_client/moon_render/moon_controller.dart';
import 'package:illunis_client/moon_render/moon_renderer.dart';

import '../moon/moon_test_fixtures.dart';
import 'fake_loader.dart';

MoonManifest manifest() =>
    (parseMoonManifest(sampleManifestText()) as ManifestOk).manifest;

Future<MoonController> pumpMoon(WidgetTester tester, FakeLoader loader) async {
  final c = MoonController(manifest: manifest(), loader: loader);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 400,
          height: 400,
          child: MoonRenderer(controller: c),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  testWidgets('builds and paints with the default map', (tester) async {
    final loader = FakeLoader(immediate: true);
    final c = await pumpMoon(tester, loader);
    expect(loader.requests, ['default.jpg']);
    expect(c.defaultImage, isNotNull);
    expect(c.screen, isNotNull);
    expect(find.byType(MoonRenderer), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MoonRenderer),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinch on the moon zooms the view', (tester) async {
    final c = await pumpMoon(tester, FakeLoader(immediate: true));
    final centre = tester.getCenter(find.byType(MoonRenderer));
    final a = await tester.startGesture(
      centre - const Offset(30, 0),
      pointer: 1,
    );
    final b = await tester.startGesture(
      centre + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    for (var i = 1; i <= 6; i++) {
      await a.moveTo(centre - Offset(30.0 + 10 * i, 0));
      await b.moveTo(centre + Offset(30.0 + 10 * i, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(c.view.zoom, greaterThan(1.5));
    // Zoomed past the default map: tiles requested and painted.
    expect(c.drawTiles, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag pans the view', (tester) async {
    final c = await pumpMoon(tester, FakeLoader(immediate: true));
    await tester.drag(find.byType(MoonRenderer), const Offset(120, 60));
    await tester.pump();
    expect(c.view.longitudeDeg, lessThan(0));
    expect(c.view.latitudeDeg, greaterThan(0));
  });

  testWidgets('voice command repaints the renderer', (tester) async {
    final c = await pumpMoon(tester, FakeLoader(immediate: true));
    expect(c.handleTranscript('zoom in on the moon'), isTrue);
    await tester.pump();
    expect(c.view.zoom, closeTo(1.5, 1e-9));
    expect(tester.takeException(), isNull);
  });
}
