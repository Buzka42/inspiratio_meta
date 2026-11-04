// The library: name and alias matching only, no suggestions, basics in
// progression order, advanced gated by the stored flag, holotropic never
// playable. Reads the synced assets.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/breath/breath_library.dart';
import 'package:illunis_client/breath/technique.dart';

import 'breath_fixtures.dart';

void main() {
  final lib = loadAssetLibrary();

  test('parses every technique file', () {
    expect(lib.all.length, 15);
    expect(lib.all.map((t) => t.id).toSet().length, 15);
  });

  group('matching', () {
    test('by name or alias, ignoring case and punctuation', () {
      expect(lib.match('Box breathing')?.id, 'box_breathing');
      expect(lib.match('box, fixed count')?.id, 'box_breathing');
      expect(lib.match('SQUARE BREATHING')?.id, 'box_breathing');
      expect(lib.match('a box breathing session')?.id, 'box_breathing');
      expect(lib.match('Longer out-breath')?.id, 'long_exhale');
      expect(lib.match('metta')?.id, 'loving_kindness');
      expect(lib.match('the body scan')?.id, 'body_scan');
    });

    test('a near miss, a description or an id is not a match', () {
      for (final t in [
        'box',
        'breathing',
        'something calming',
        'help me sleep',
        'boxbreathing',
        'breath',
        '',
      ]) {
        expect(lib.match(t), isNull, reason: t);
      }
    });

    test('the library has no suggestion entry point', () {
      // Only explicit lookups exist: a match needs a typed name.
      expect(lib.match('I feel stressed'), isNull);
      expect(lib.match('what should I do'), isNull);
    });
  });

  test('basic techniques list in progression order', () {
    expect(lib.basics().map((t) => t.id), [
      'breath_observation',
      'paced_breath',
      'long_exhale',
      'cyclic_sighing',
      'box_breathing',
      'breath_counting',
      'body_scan',
      'loving_kindness',
    ]);
    expect(lib.basics().map((t) => t.progressionOrder), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  group('advanced gating', () {
    test('the list shows advanced techniques only for an advanced practitioner', () {
      expect(lib.listFor(advanced: false).every((t) => t.isBasic), isTrue);
      final all = lib.listFor(advanced: true);
      expect(all.take(8).map((t) => t.id), lib.basics().map((t) => t.id));
      expect(all.skip(8).every((t) => !t.isBasic), isTrue);
      expect(all.length, 15);
    });

    test('an advanced technique starts only with the stored flag', () {
      final ujjayi = lib.byId('ujjayi')!;
      expect(ujjayi.level, TechniqueLevel.advanced);
      expect(lib.refusal(ujjayi, advanced: false), BreathRefusal.advancedOnly);
      expect(lib.refusal(ujjayi, advanced: true), isNull);
      expect(lib.refusal(lib.byId('kapalabhati')!, advanced: true), BreathRefusal.unavailable);
    });

    test('basic techniques start without the flag', () {
      for (final t in lib.basics()) {
        expect(lib.refusal(t, advanced: false), isNull, reason: t.id);
      }
    });
  });

  test('holotropic can be named and explained but is never playable', () {
    final h = lib.match('holotropic breathing')!;
    expect(h.id, 'holotropic');
    expect(h.available, isFalse);
    expect(h.playable, isFalse);
    expect(lib.refusal(h, advanced: true), BreathRefusal.referenceOnly);
    expect(lib.refusal(h, advanced: false), BreathRefusal.referenceOnly);
    expect(h.copy.notice, contains('not medical advice'));
  });
}
