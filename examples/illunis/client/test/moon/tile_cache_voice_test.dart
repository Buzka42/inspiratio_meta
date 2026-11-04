import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/moon/tile_cache.dart';
import 'package:illunis_client/moon/voice_zoom.dart';

void main() {
  group('TileCache', () {
    test('evicts least recently used', () {
      final disposed = <String>[];
      final c = TileCache<int>(capacity: 3, onEvict: (n, _) => disposed.add(n));
      c.put('a', 1);
      c.put('b', 2);
      c.put('c', 3);
      c.get('a');
      expect(c.put('d', 4), ['b']);
      expect(disposed, ['b']);
      expect(c.names, ['c', 'a', 'd']);
    });

    test('eviction keeps visible tiles', () {
      final c = TileCache<int>(capacity: 2);
      c.put('a', 1);
      c.put('b', 2);
      c.setVisible(['a', 'b']);
      // Over capacity, but everything older is in view.
      expect(c.put('c', 3), isEmpty);
      c.setVisible(['a', 'b', 'c']);
      expect(c.length, 3);
      // View moves: only out-of-view tiles go, oldest first.
      expect(c.setVisible(['c']), ['a']);
      expect(c.names, ['b', 'c']);
      expect(c.put('d', 4), ['b']);
      expect(c.contains('c'), isTrue);
    });

    test('never evicts the visible tile even if least recent', () {
      final c = TileCache<int>(capacity: 2);
      c.put('v', 0);
      c.setVisible(['v']);
      c.put('x', 1);
      c.put('y', 2);
      expect(c.contains('v'), isTrue);
      expect(c.contains('x'), isFalse);
    });

    test('replacing a tile disposes the old value', () {
      final disposed = <int>[];
      final c = TileCache<int>(capacity: 2, onEvict: (_, v) => disposed.add(v));
      c.put('a', 1);
      c.put('a', 2);
      expect(disposed, [1]);
      expect(c.get('a'), 2);
    });
  });

  group('voice zoom', () {
    test('intents parse', () {
      expect(parseMoonZoom('zoom in on the moon'), MoonZoomAction.zoomIn);
      expect(parseMoonZoom('Zoom in on the Moon.'), MoonZoomAction.zoomIn);
      expect(parseMoonZoom('  zoom   in '), MoonZoomAction.zoomIn);
      expect(parseMoonZoom('zoom out'), MoonZoomAction.zoomOut);
      expect(parseMoonZoom('Zoom out, please'), MoonZoomAction.zoomOut);
      expect(parseMoonZoom('reset the moon'), MoonZoomAction.reset);
      expect(parseMoonZoom('Reset the moon!'), MoonZoomAction.reset);
    });

    test('unknown text is ignored', () {
      for (final t in [
        '',
        'zoom',
        'zoom in on the sun',
        'what is the moon phase',
        'reset the alarm',
        'do not zoom in on the moon',
        'zoom in on the moon and set an alarm',
      ]) {
        expect(parseMoonZoom(t), isNull, reason: t);
      }
    });
  });
}
