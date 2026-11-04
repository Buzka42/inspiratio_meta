import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/input_ports.dart';
import 'package:illunis_client/input/input_stubs.dart';
import 'package:illunis_client/input/wake/sherpa_wake_engine.dart';
import 'package:illunis_client/input/wake/wake_phrase.dart';
import 'package:illunis_client/input/wake_engine_adapter.dart';
import 'package:illunis_client/voice/voice_session.dart';
import 'package:illunis_client/voice/wake_keyword.dart';
import 'package:illunis_client/voice/wake_wiring.dart';

class TaggedPort implements WakeWordPort {
  TaggedPort(this.tag, [this.phrase]);
  final String tag;
  final WakePhrase? phrase;
  var listens = 0;

  @override
  Stream<WakeWordHeard> listen(Stream<Uint8List> audio, WakeKeyword keyword,
      {required int sampleRate}) {
    listens++;
    return const Stream.empty();
  }
}

const base = '/data/files';
final modelDir = kwsModelDir(base);

void main() {
  final legacy = TaggedPort('legacy');
  final logs = <String>[];
  setUp(logs.clear);

  WakeWordPort pick(String? phrase, {required bool modelPresent}) => chooseWakeWordPort(
        legacy: legacy,
        enginePhrase: phrase,
        modelDir: modelDir,
        exists: (_) => modelPresent,
        log: logs.add,
        buildEngine: (p, m) => TaggedPort('engine', p),
      );

  test('model dir follows the support-dir pattern', () {
    expect(kwsModelDir('/data/files/'), '/data/files/models/kws/$kwsModelName');
    expect(modelDir, '$base/$kwsModelSubdir');
  });

  test('engine only with a valid phrase and a present model', () {
    final p = pick('Hey Vega', modelPresent: true) as TaggedPort;
    expect(p.tag, 'engine');
    expect(p.phrase?.text, 'hey vega');
    expect(pick('Hey Vega', modelPresent: false), same(legacy));
    expect(pick(null, modelPresent: true), same(legacy));
    expect(pick('vega', modelPresent: true), same(legacy)); // One word: invalid phrase.
    expect(pick('good morning', modelPresent: true), same(legacy));
  });

  test('a missing model logs a code only', () {
    pick('hey vega', modelPresent: false);
    expect(logs, ['input: wake_engine_off code=$wakeModelMissing']);
  });

  test('every model file must exist', () {
    final files = SherpaKwsModel.inDir(modelDir).files;
    final port = chooseWakeWordPort(
      legacy: legacy,
      enginePhrase: 'hey vega',
      modelDir: modelDir,
      exists: (f) => f != files.last,
      log: logs.add,
      buildEngine: (p, m) => TaggedPort('engine', p),
    );
    expect(port, same(legacy));
  });

  test('sherpaWakePort is an adapter falling back to the legacy port', () {
    final port = sherpaWakePort(
        WakePhrase.tryCreate('hey vega')!, SherpaKwsModel.inDir(modelDir), StubWakeWordPort());
    expect(port, isA<WakeEngineAdapter>());
  });

  test('switching port re-chooses when the stored phrase changes', () {
    String? stored;
    final chosen = <String?>[];
    final ports = <TaggedPort>[];
    final port = PhraseSwitchingWakePort(
      phrase: () => stored,
      choose: (p) {
        chosen.add(p);
        final t = TaggedPort(p == null ? 'legacy' : 'engine');
        ports.add(t);
        return t;
      },
    );
    final kw = WakeKeyword.tryCreate('vega')!;
    final audio = StreamController<Uint8List>.broadcast().stream;
    port.listen(audio, kw, sampleRate: 16000);
    port.listen(audio, kw, sampleRate: 16000);
    expect(chosen, [null]);
    stored = 'hey vega';
    port.listen(audio, kw, sampleRate: 16000);
    expect(chosen, [null, 'hey vega']);
    expect((port.current! as TaggedPort).tag, 'engine');
    expect(ports.first.listens, 2);
  });
}
