import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/captions/caption_dissolve.dart';
import 'package:illunis_client/captions/caption_timing.dart';
import 'package:illunis_client/captions/caption_view.dart';

const _text = 'The tide turns at dawn';

Future<ui.FragmentProgram?> _noShader() async => null;

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: Center(child: child)),
      ),
    );

Future<ui.FragmentProgram> _realProgram(WidgetTester t) async =>
    (await t.runAsync(() => ui.FragmentProgram.fromAsset(CaptionDissolveShader.assetKey)))!;

void main() {
  testWidgets('caption carries a Semantics label and a dismiss hint', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(_host(const CaptionView(text: _text, programLoader: _noShader)));
    expect(find.bySemanticsLabel(_text), findsOneWidget);
    final node = t.getSemantics(find.bySemanticsLabel(_text));
    final data = node.getSemanticsData();
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
    expect(data.flagsCollection.isLiveRegion, isTrue);
    h.dispose();
  });

  testWidgets('shader unavailable: tap fades out with opacity and calls onDismissed', (t) async {
    var gone = 0;
    await t.pumpWidget(_host(
        CaptionView(text: _text, programLoader: _noShader, onDismissed: () => gone++)));
    await t.pump();
    expect(t.state<CaptionViewState>(find.byType(CaptionView)).exitMode, CaptionExit.fade);
    await t.tap(find.byType(CaptionView));
    await t.pump(); // first frame starts the exit ticker
    await t.pump(const Duration(milliseconds: 750));
    expect(find.byKey(const ValueKey('caption-fade')), findsOneWidget);
    expect(find.byKey(const ValueKey('caption-dissolve')), findsNothing);
    final op = t.widget<Opacity>(find.byKey(const ValueKey('caption-fade'))).opacity;
    expect(op, inExclusiveRange(0.0, 1.0));
    await t.pump(captionFade);
    expect(gone, 1);
    expect(find.text(_text), findsNothing);
  });

  testWidgets('hold runs out on its own: 4 s + 0.3 s per word', (t) async {
    var gone = 0;
    await t.pumpWidget(_host(
        CaptionView(text: _text, programLoader: _noShader, onDismissed: () => gone++)));
    final hold = captionHold(_text); // 5 words -> 5.5 s
    await t.pump(hold - const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('caption-fade')), findsNothing);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('caption-fade')), findsOneWidget);
    await t.pump();
    await t.pump(captionFade + const Duration(milliseconds: 20)); // slack: ticker starts a frame late
    expect(gone, 1);
  });

  testWidgets('visible false starts the exit; visible true shows it again', (t) async {
    await t.pumpWidget(_host(const CaptionView(text: _text, programLoader: _noShader)));
    await t.pumpWidget(
        _host(const CaptionView(text: _text, visible: false, programLoader: _noShader)));
    await t.pump();
    await t.pump(captionFade + const Duration(milliseconds: 10));
    expect(find.text(_text), findsNothing);
    await t.pumpWidget(_host(const CaptionView(text: _text, programLoader: _noShader)));
    expect(find.text(_text), findsOneWidget);
  });

  testWidgets('shader loaded: tap dissolves through the shader', (t) async {
    final program = await _realProgram(t);
    var gone = 0;
    await t.pumpWidget(_host(CaptionView(
        text: _text, programLoader: () async => program, onDismissed: () => gone++)));
    await t.pump();
    expect(t.state<CaptionViewState>(find.byType(CaptionView)).exitMode, CaptionExit.dissolve);
    await t.tap(find.byType(CaptionView));
    await t.pump(); // first frame starts the exit ticker
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('caption-dissolve')), findsOneWidget);
    await t.pump(captionFade);
    expect(gone, 1);
  });

  testWidgets('reduced motion: no shader even when loaded, short fade', (t) async {
    final program = await _realProgram(t);
    var gone = 0;
    await t.pumpWidget(_host(
        CaptionView(text: _text, programLoader: () async => program, onDismissed: () => gone++),
        reduceMotion: true));
    await t.pump();
    expect(t.state<CaptionViewState>(find.byType(CaptionView)).exitMode, CaptionExit.quickFade);
    await t.tap(find.byType(CaptionView));
    await t.pump(); // first frame starts the exit ticker
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('caption-dissolve')), findsNothing);
    expect(find.byKey(const ValueKey('caption-fade')), findsOneWidget);
    await t.pump(captionQuickFade);
    expect(gone, 1);
  });

  testWidgets('fog off: plain fade even with the shader loaded', (t) async {
    final program = await _realProgram(t);
    await t.pumpWidget(_host(
        CaptionView(text: _text, fog: false, programLoader: () async => program)));
    await t.pump();
    expect(t.state<CaptionViewState>(find.byType(CaptionView)).exitMode, CaptionExit.fade);
  });

  test('uniform layout matches caption_dissolve.frag', () {
    final u = CaptionDissolveShader.uniforms(const Size(300, 80), 1.7, 0.25);
    expect(u, [300, 80, 1.0, 0.25]);
    expect(u.length, CaptionDissolveShader.floatCount);
  });

  testWidgets('shader: progress 0 is the input, progress 1 is transparent', (t) async {
    final program = await _realProgram(t);
    const w = 64, h = 48;
    final result = await t.runAsync(() async {
      final src = _solidImage(w, h);
      final at0 = await _render(program, src, w, h, 0);
      final mid = await _render(program, src, w, h, 0.5);
      final at1 = await _render(program, src, w, h, 1);
      return (at0, mid, at1);
    });
    final (at0, mid, at1) = result!;
    double alphaSum(Uint8List p) {
      var s = 0.0;
      for (var i = 3; i < p.length; i += 4) {
        s += p[i];
      }
      return s / (p.length / 4);
    }

    // Opaque input with a 1 px clear border: centre pixels stay opaque at 0.
    expect(at0[((h ~/ 2) * w + w ~/ 2) * 4 + 3], 255);
    expect(alphaSum(at0), greaterThan(200));
    expect(alphaSum(mid), inExclusiveRange(1.0, alphaSum(at0)));
    expect(alphaSum(at1), 0);
  });
}

ui.Image _solidImage(int w, int h) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(1, 1, w - 2.0, h - 2.0),
      ui.Paint()..color = const ui.Color(0xFF1C2333));
  return rec.endRecording().toImageSync(w, h);
}

Future<Uint8List> _render(ui.FragmentProgram p, ui.Image src, int w, int h, double t) async {
  final rec = ui.PictureRecorder();
  final shader = p.fragmentShader();
  CaptionDissolvePainter(shader: shader, image: src, progress: t, seed: 0.3)
      .paint(ui.Canvas(rec), Size(w.toDouble(), h.toDouble()));
  final img = await rec.endRecording().toImage(w, h);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bytes!.buffer.asUint8List();
}
