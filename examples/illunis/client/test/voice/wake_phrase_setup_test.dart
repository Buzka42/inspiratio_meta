import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/input/wake/wake_phrase.dart';
import 'package:illunis_client/voice/wake_phrase_setup.dart';

class Rig {
  Rig({this.ready = true, StateStore? store}) : store = store ?? InMemoryStateStore();

  final StateStore store;
  late final setup = WakePhraseSetup(
    store: WakePhraseStore(read: store.getString, write: store.setString),
    speak: (t) async => spoken.add(t),
    listen: () => listens++,
    onPhraseChanged: () => changes++,
    ready: () => ready,
    log: logs.add,
  );
  bool ready;
  final spoken = <String>[];
  final logs = <String>[];
  var listens = 0;
  var changes = 0;
}

void main() {
  group('parsing', () {
    test('strips leads and filler, keeps the words', () {
      final a = parseWakePhraseAnswer('My wake phrase is Hey, Vega please');
      expect((a as PhraseText).text, 'hey vega');
    });

    test('none declines; silence is unreadable', () {
      expect(parseWakePhraseAnswer('No thanks.'), isA<DeclinePhrase>());
      expect(parseWakePhraseAnswer('  ...  '), isNull);
    });

    test('change my wake phrase, with and without a value', () {
      expect(parseWakePhraseIntent('Please change my wake phrase to hey Vega.')?.value, 'hey vega');
      expect(parseWakePhraseIntent('set the wake phrase'), isNotNull);
      expect(parseWakePhraseIntent('set the wake phrase')!.value, isNull);
      expect(parseWakePhraseIntent('change my wake word to vega'), isNull);
    });
  });

  group('capture', () {
    test('offer asks once the interview is done, then accepts a valid phrase', () async {
      final r = Rig();
      await r.setup.offer();
      expect(r.spoken.single, WakePhrasePrompt.offer);
      expect(r.listens, 1);
      expect(r.setup.claim('Hey Vega'), isTrue);
      await r.setup.settled;
      expect(r.setup.phrase, WakePhrase.tryCreate('hey vega'));
      expect(r.setup.asking, isFalse);
      expect(r.spoken.last, 'Your wake phrase is now hey vega.');
      expect(r.changes, 1);
      expect(r.listens, 1); // No listen after the confirmation.
    });

    test('an invalid phrase gets a spoken retry with the reason and stays asking', () async {
      final r = Rig();
      await r.setup.offer();
      r.setup.claim('Vega');
      await r.setup.settled;
      expect(r.spoken.last, WakePhrasePrompt.rejected(WakePhraseRejection.tooFewWords));
      r.setup.claim('good morning');
      await r.setup.settled;
      expect(r.spoken.last, WakePhrasePrompt.rejected(WakePhraseRejection.bareGreeting));
      expect(r.setup.asking, isTrue);
      expect(r.setup.phrase, isNull);
      expect(r.changes, 0);
      expect(r.listens, 3);
      expect(r.logs, contains('setup: wake_phrase_rejected code=tooFewWords'));
      expect(r.logs.join('\n'), isNot(contains('morning'))); // Codes only.

      r.setup.claim('hey there vega');
      await r.setup.settled;
      expect(r.setup.phrase?.text, 'hey there vega');
      expect(r.changes, 1);
    });

    test('none keeps the single word and is not asked again', () async {
      final r = Rig();
      await r.setup.offer();
      r.setup.claim('none');
      await r.setup.settled;
      expect(r.setup.declined, isTrue);
      expect(r.setup.phrase, isNull);
      expect(r.spoken.last, WakePhrasePrompt.declined);
      r.spoken.clear();
      await r.setup.offer();
      expect(r.spoken, isEmpty);
    });

    test('not offered or claimed while the interview runs', () async {
      final r = Rig(ready: false);
      await r.setup.offer();
      expect(r.spoken, isEmpty);
      expect(r.setup.claim('change my wake phrase to hey vega'), isFalse);
    });

    test('another setup change while asking is released to VoiceSetup', () async {
      final r = Rig();
      await r.setup.offer();
      expect(r.setup.claim('change my alarm to 6:45'), isFalse);
      expect(r.setup.asking, isFalse);
      expect(r.setup.claim('hello there'), isFalse); // No longer asking.
    });

    test('spoken change later replaces the phrase; one without a value asks', () async {
      final r = Rig();
      expect(r.setup.claim('change my wake phrase to hey vega'), isTrue);
      await r.setup.settled;
      expect(r.setup.phrase?.text, 'hey vega');
      expect(r.setup.claim('change my wake phrase'), isTrue);
      await r.setup.settled;
      expect(r.spoken.last, WakePhrasePrompt.edit);
      r.setup.claim('altair awake');
      await r.setup.settled;
      expect(r.setup.phrase?.text, 'altair awake');
      expect(r.changes, 2);
    });
  });

  group('storage', () {
    test('the stored phrase round-trips through the store', () async {
      final store = InMemoryStateStore();
      final r = Rig(store: store);
      await r.setup.offer();
      r.setup.claim('Hey, Vega!');
      await r.setup.settled;
      expect(await store.getString(wakePhraseKey), '{"phrase":"hey vega"}');

      final again = Rig(store: store);
      await again.setup.load();
      expect(again.setup.phrase, WakePhrase.tryCreate('hey vega'));
      await again.setup.offer();
      expect(again.spoken, isEmpty); // Already answered.
    });

    test('declined round-trips; malformed or invalid input asks again', () {
      expect(StoredWakePhrase.decode(const StoredWakePhrase(declined: true).encode()).declined, isTrue);
      expect(StoredWakePhrase.decode('not json').answered, isFalse);
      expect(StoredWakePhrase.decode('[1]').answered, isFalse);
      expect(StoredWakePhrase.decode('{"phrase":"vega"}').answered, isFalse);
      expect(StoredWakePhrase.decode(null).answered, isFalse);
    });
  });
}
