import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_gpu/illunis_gpu.dart';

void main() {
  Widget fallback(BuildContext _) => const SizedBox(key: ValueKey('fallback'));

  testWidgets('shows the fallback while there is no sky', (t) async {
    await t.pumpWidget(GpuWater(sky: null, fallback: fallback));
    expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
  });

  testWidgets('stays on the fallback when Flutter GPU is unavailable', (t) async {
    final sky = await t.runAsync(() async {
      final r = ui.PictureRecorder();
      Canvas(r).drawPaint(Paint());
      return r.endRecording().toImage(4, 2);
    });
    await t.pumpWidget(GpuWater(
        sky: sky,
        fallback: fallback,
        factory: (_, _) => Future.error(StateError('no gpu'))));
    await t.pump();
    expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
    expect(find.byKey(const ValueKey('water-gpu')), findsNothing);
  });
}
