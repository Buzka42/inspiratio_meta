import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/moon_manifest.dart';
import 'package:illunis_client/moon_render/moon_controller.dart';

import '../moon/moon_test_fixtures.dart';
import 'fake_loader.dart';

MoonManifest manifest() =>
    (parseMoonManifest(sampleManifestText()) as ManifestOk).manifest;

// 1080x2400 physical, like the phone the selector was sized for.
const logical = ui.Size(540, 1200);
const dpr = 2.0;

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('default map first, no tiles at zoom 1', () async {
    final loader = FakeLoader();
    final ready = <String>[];
    final c = MoonController(
      manifest: manifest(),
      loader: loader,
      onTileReady: ready.add,
    );
    var notified = 0;
    c.addListener(() => notified++);
    c.setScreen(logical, dpr);
    c.start();
    expect(loader.requests, ['default.jpg']);
    expect(c.defaultImage, isNull);

    loader.complete('default.jpg');
    await settle();
    expect(c.defaultImage, isNotNull);
    expect(ready, ['default.jpg']);
    expect(notified, 1);
    expect(c.wantedTiles, isEmpty);
    expect(c.drawTiles, isEmpty);
    c.dispose();
  });

  test('zoom asks for tiles; each is drawn only after it loads', () async {
    final loader = FakeLoader();
    final ready = <String>[];
    final c = MoonController(
      manifest: manifest(),
      loader: loader,
      onTileReady: ready.add,
      maxConcurrentLoads: 3,
    );
    c.setScreen(logical, dpr);
    c.start();
    loader.complete('default.jpg');
    await settle();

    expect(c.handleTranscript('zoom in on the moon'), isTrue); // 1.5
    expect(c.handleTranscript('zoom in'), isTrue); // 2.25 > 1.51: tiles
    expect(c.view.zoom, closeTo(2.25, 1e-9));
    final wanted = c.wantedTiles;
    expect(wanted, isNotEmpty);
    expect(wanted.every((f) => f.startsWith('tiles/L0_')), isTrue);
    // At most three in flight; nothing drawn yet, default still there.
    expect(loader.pending.length, 3);
    expect(c.drawTiles, isEmpty);
    expect(c.defaultImage, isNotNull);

    final first = loader.pending.keys.first;
    loader.complete(first);
    await settle();
    expect(c.drawTiles.map((t) => t.file), [first]);
    expect(
      identical(c.drawTiles.single.image, loader.delivered[first]),
      isTrue,
    );
    expect(ready.last, first);
    // A slot freed, so the next wanted tile started.
    expect(loader.pending.length, 3);

    await loader.completeAll();
    expect(c.drawTiles.map((t) => t.file).toSet(), wanted.toSet());
    c.dispose();
  });

  test('eviction disposes the tile image through the callback', () async {
    final loader = FakeLoader();
    final freed = <String>[];
    final c = MoonController(
      manifest: manifest(),
      loader: loader,
      cacheCapacity: 2,
      onTileFreed: freed.add,
    );
    c.setScreen(logical, dpr);
    c.start();
    c.handleTranscript('zoom in');
    c.handleTranscript('zoom in');
    await loader.completeAll();
    final before = c.wantedTiles;
    expect(before.length, greaterThan(2));
    // Visible tiles stay even over capacity.
    expect(c.cache.length, before.length);
    expect(freed, isEmpty);

    // Turn to the far side: the old tiles leave the view.
    c.view.centreOn(180, 0);
    c.beginPinch();
    c.updatePinch(1, ui.Offset.zero);
    expect(c.wantedTiles.toSet().intersection(before.toSet()), isEmpty);
    expect(freed.length, before.length - 2);
    for (final f in freed) {
      expect(before, contains(f));
      expect(loader.delivered[f]!.debugDisposed, isTrue);
    }
    final kept = before.where((f) => !freed.contains(f));
    for (final f in kept) {
      expect(loader.delivered[f]!.debugDisposed, isFalse);
    }
    c.dispose();
    expect(loader.delivered['default.jpg']!.debugDisposed, isTrue);
  });

  test('failed tile keeps the default and is not retried', () async {
    final loader = FakeLoader();
    final c = MoonController(
      manifest: manifest(),
      loader: loader,
      maxConcurrentLoads: 1,
    );
    c.setScreen(logical, dpr);
    c.start();
    loader.complete('default.jpg');
    c.handleTranscript('zoom in');
    c.handleTranscript('zoom in');
    final bad = loader.pending.keys.single;
    loader.fail(bad);
    await settle();
    c.handleTranscript('zoom in');
    expect(loader.requests.where((f) => f == bad).length, 1);
    expect(c.defaultImage, isNotNull);
    c.dispose();
  });

  test('a load that finishes after dispose is freed', () async {
    final loader = FakeLoader();
    final c = MoonController(manifest: manifest(), loader: loader);
    c.setScreen(logical, dpr);
    c.start();
    c.dispose();
    loader.complete('default.jpg');
    await settle();
    expect(loader.delivered['default.jpg']!.debugDisposed, isTrue);
  });

  test('voice and pinch drive the view', () {
    final c = MoonController(manifest: manifest(), loader: FakeLoader());
    c.setScreen(logical, dpr);
    expect(
      c.view.maxZoom,
      closeTo(8192 * 1.25 / (2 * 3.141592653589793 * 540 * 0.92), 1e-6),
    );
    expect(c.handleTranscript('what time is it'), isFalse);
    expect(c.view.zoom, 1);
    c.handleTranscript('Zoom in on the Moon.');
    expect(c.view.zoom, closeTo(1.5, 1e-9));
    c.handleTranscript('reset the moon');
    expect(c.view.zoom, 1);

    c.beginPinch();
    c.updatePinch(2, ui.Offset.zero);
    expect(c.view.zoom, closeTo(2, 1e-9));
    // Drag right by 50 logical = 100 physical px: lon moves west.
    c.updatePinch(2, const ui.Offset(50, 0));
    final radius = 540 * 0.92 * 2;
    expect(
      c.view.longitudeDeg,
      closeTo(-100 / radius * 180 / 3.141592653589793, 1e-9),
    );
    c.dispose();
  });
}
