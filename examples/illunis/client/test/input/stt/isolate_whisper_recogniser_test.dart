// Real sherpa-onnx Whisper decode on the worker isolate, using the eval/stt
// benchmark model and LibriSpeech sample on this machine (not in the app, not
// bundled). Skipped when the files are not there or the native library does
// not load under `flutter test`.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/input/stt/whisper_model.dart';
import 'package:illunis_client/input/stt/whisper_recogniser.dart';

const _evalDir = '../eval/stt/models/$whisperModelName';

/// 16-bit mono WAV (canonical 44-byte header) to floats.
(Float32List, int) _readWav(String path) {
  final b = File(path).readAsBytesSync();
  final d = ByteData.sublistView(b);
  final rate = d.getUint32(24, Endian.little);
  var off = 12;
  while (off + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(off, off + 4));
    final size = d.getUint32(off + 4, Endian.little);
    if (id == 'data') {
      final n = size ~/ 2;
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = d.getInt16(off + 8 + i * 2, Endian.little) / 32768.0;
      }
      return (out, rate);
    }
    off += 8 + size;
  }
  throw StateError('no data chunk');
}

void main() {
  final model = WhisperModel.inDir(_evalDir);
  final present = model.missing().isEmpty && File('$_evalDir/test_wavs/0.wav').existsSync();

  test('decodes a LibriSpeech sample off the UI isolate', () async {
    final lib = '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
        'sherpa_onnx_linux-2.0.0/linux/x64';
    final rec = IsolateWhisperRecogniser(model, nativeLibDir: lib)..warmUp();
    addTearDown(rec.dispose);
    final (samples, rate) = _readWav('$_evalDir/test_wavs/0.wav');
    final String text;
    try {
      text = await rec.recognise(samples, rate);
    } on WhisperFailure catch (e) {
      if (e.code == sttLoadFailed) {
        markTestSkipped('native sherpa-onnx did not load under flutter test');
        return;
      }
      rethrow;
    }
    expect(text.toLowerCase(), contains('yellow lamps'));
  }, skip: present ? false : 'eval/stt model not on this machine', timeout: const Timeout(Duration(minutes: 2)));
}
