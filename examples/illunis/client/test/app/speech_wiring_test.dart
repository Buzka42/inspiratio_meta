import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/speech_wiring.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/output/kokoro/kokoro_engine.dart';
import 'package:illunis_client/output/kokoro/kokoro_factory.dart';
import 'package:illunis_client/output/kokoro/kokoro_fakes.dart';
import 'package:illunis_client/output/tts_engine.dart';

// Fakes only. Nothing here touches native code or the file system.
void main() {
  late FakePcmPlayer player;
  late TtsEngine fallback;
  late List<String> logs;
  late List<String> dirs;

  KokoroBuild build(String dir, {required bool checked}) {
    dirs.add(dir);
    return buildKokoroSpeech(dir,
        voice: kokoroAppVoice,
        releaseChecked: checked,
        player: () => player,
        loader: (_, _) async => FakeSynthBackend());
  }

  setUp(() {
    player = FakePcmPlayer();
    fallback = TtsPortEngine(SilentTts());
    logs = [];
    dirs = [];
  });

  group('kokoroModelDir', () {
    test('joins the base directory and the model subfolder', () {
      expect(kokoroModelDir('/data/user/0/com.illunis.illunis_client/files'),
          '/data/user/0/com.illunis.illunis_client/files/models/kokoro-multi-lang-v1_0');
    });

    test('drops a trailing slash on the base', () {
      expect(kokoroModelDir('/base/'), '/base/models/kokoro-multi-lang-v1_0');
    });
  });

  group('chooseSpeechEngine', () {
    test('ready build gives the Kokoro engine', () {
      final b = build('/m', checked: true);
      expect(chooseSpeechEngine(b, fallback), isA<KokoroTtsEngine>());
    });

    test('refused build gives the fallback', () {
      final b = build('/m', checked: false);
      expect(chooseSpeechEngine(b, fallback), same(fallback));
    });
  });

  group('wireSpeech', () {
    test('licence refused: fallback, code logged, model dir passed', () async {
      final w = await wireSpeech('/base',
          fallback: fallback,
          build: (d) => build(d, checked: false),
          exists: (_) => fail('model not checked when refused'),
          log: logs.add);
      expect(w.engine, same(fallback));
      expect(w.refusal, KokoroRefusal.licence);
      expect(w.kokoro, isFalse);
      expect(dirs, ['/base/models/kokoro-multi-lang-v1_0']);
      expect(logs, ['speech: kokoro_off code=kokoro_licence_refused']);
      await w.dispose();
    });

    test('ready with every model file: Kokoro, nothing logged', () async {
      final seen = <String>[];
      final w = await wireSpeech('/base',
          fallback: fallback,
          build: (d) => build(d, checked: true),
          exists: (p) {
            seen.add(p);
            return true;
          },
          log: logs.add);
      expect(w.engine, isA<KokoroTtsEngine>());
      expect(w.kokoro, isTrue);
      expect(seen, [for (final f in kokoroModelFiles) '/base/models/kokoro-multi-lang-v1_0/$f']);
      expect(logs, isEmpty);
      await w.dispose();
      expect(player.disposed, isTrue);
    });

    test('ready but a model file missing: fallback, player released', () async {
      final w = await wireSpeech('/base',
          fallback: fallback,
          build: (d) => build(d, checked: true),
          exists: (p) => !p.endsWith('voices.bin'),
          log: logs.add);
      expect(w.engine, same(fallback));
      expect(w.refusal, kokoroModelMissing);
      expect(player.disposed, isTrue);
      expect(logs, ['speech: kokoro_off code=kokoro_model_missing']);
    });

    test('logs carry no path', () async {
      await wireSpeech('/secret-base',
          fallback: fallback,
          build: (d) => build(d, checked: true),
          exists: (_) => false,
          log: logs.add);
      expect(logs.join(), isNot(contains('secret-base')));
    });
  });
}
