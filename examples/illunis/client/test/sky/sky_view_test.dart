import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/sky/celestial_scene.dart';
import 'package:illunis_client/sky/sky_painter.dart';
import 'package:illunis_client/sky/sky_state.dart';
import 'package:illunis_client/sky/sky_view.dart';

void main() {
  final state = SkyState.at(DateTime.utc(2026, 12, 21, 21),
      latitudeDeg: 52.23, longitudeDeg: 21.01);

  testWidgets('SkyView builds and ticks without a device (fallback)',
      (t) async {
    ResolvedScene? seen;
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 200,
        height: 400,
        child: SkyView(
          state: state,
          loadShader: false,
          onScene: (s) => seen = s,
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    final paint = t.widget<CustomPaint>(find.descendant(
        of: find.byType(SkyView), matching: find.byType(CustomPaint)));
    expect(paint.painter, isA<SkyPainter>());
    expect((paint.painter! as SkyPainter).shader, isNull);
    expect(seen, isNotNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('SkyView with the shader requested still builds', (t) async {
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SkyView(state: state),
    ));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byType(SkyView), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox()); // dispose while loading is safe
  });
}
