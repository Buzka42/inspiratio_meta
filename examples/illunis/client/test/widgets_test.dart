import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/widgets/classic_sky.dart';
import 'package:illunis_client/widgets/water_pass.dart';

void main() {
  testWidgets('WaterPass falls back when the shader fails to load', (t) async {
    await t.pumpWidget(MaterialApp(
        home: WaterPass(programLoader: () => Future.error(StateError('no shader')))));
    await t.pump();
    expect(find.byKey(const ValueKey('water-fallback')), findsOneWidget);
  });

  testWidgets('ClassicSky renders at night', (t) async {
    await t.pumpWidget(MaterialApp(
        home: ClassicSky(lat: 51.5, lng: 0, now: DateTime.utc(2024, 6, 21, 0))));
    expect(find.byType(ClassicSky), findsOneWidget);
  });
}
