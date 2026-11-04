// Pure parts of the sherpa engine only; native spotting needs the model
// files and a device, so it is not run here.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/wake/bpe_keyword_encoder.dart';
import 'package:illunis_client/input/wake/sherpa_wake_engine.dart';
import 'package:illunis_client/input/wake/wake_phrase.dart';

void main() {
  // Tiny SentencePiece-style vocab: higher score merges first.
  const vocab = '<unk>\t0\n'
      '▁\t-1\nH\t-1\nE\t-1\nY\t-1\nN\t-1\nO\t-1\nV\t-1\nA\t-1\n'
      '▁H\t-2\nEY\t-3\n▁HEY\t-4\n'
      'OV\t-5\n▁N\t-6\nOVA\t-9\n';
  final encoder = BpeKeywordEncoder.fromVocab(vocab);
  final phrase = WakePhrase.tryCreate('Hey Nova')!;

  test('BPE encodes each word from ▁ by best-scoring merges', () {
    expect(encoder.encode(phrase), ['▁HEY', '▁N', 'OVA']);
  });

  test('keyword line carries boost, threshold and display name', () {
    expect(encoder.keywordLine(phrase, boost: 1.5, threshold: 0.25),
        '▁HEY ▁N OVA :1.5 #0.25 @hey_nova');
    expect(encoder.keywordLine(phrase), '▁HEY ▁N OVA @hey_nova');
  });

  test('unknown character throws FormatException', () {
    expect(() => encoder.encode(WakePhrase.tryCreate('hey zed')!), throwsFormatException);
  });

  test('pcm16ToFloat32 scales little-endian samples', () {
    final pcm = Uint8List.fromList([0x00, 0x00, 0xff, 0x7f, 0x00, 0x80, 0x01]);
    expect(pcm16ToFloat32(pcm), [0.0, 32767 / 32768, -1.0]);
  });

  test('model layout and missing-file check', () async {
    final m = SherpaKwsModel.inDir('/nonexistent/$kwsModelName');
    expect(m.files, hasLength(5));
    expect(m.missing(), m.files);
  });
}
