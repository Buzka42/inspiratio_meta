/// Real Kokoro backend on sherpa-onnx (Apache-2.0). Expects the
/// `kokoro-multi-lang-v1_0` layout: model.onnx, voices.bin, tokens.txt,
/// lexicon-us-en.txt and lexicon-gb-en.txt. sherpa-onnx 2.0.0 no longer
/// reads espeak-ng-data, so that folder must not be bundled.
///
/// generate() is a blocking FFI call, so the model lives on a worker isolate
/// (like the Whisper recogniser): on the UI isolate it froze the app into
/// "not responding" on the Blade (device test 2026-10-25).
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'kokoro_licence.dart';
import 'kokoro_voices.dart';
import 'synth_backend.dart';

class SherpaKokoroBackend implements SynthBackend {
  SherpaKokoroBackend._(this._worker, this._isolate, this.sampleRate);

  final SendPort _worker;
  final Isolate _isolate;
  bool _disposed = false;

  /// A sentence that takes longer than this fails; only catches a stuck worker.
  static const synthTimeout = Duration(seconds: 30);

  @override
  final int sampleRate;

  /// Refuses (throws [KokoroLicenceRefused]) before any native code loads
  /// unless the release check is confirmed.
  static Future<SynthBackend> load(
    String modelDir,
    KokoroVoice voice, {
    bool releaseChecked = kokoroGplCheckedFlag,
    int numThreads = 2,
  }) async {
    checkKokoroLicence(releaseChecked: releaseChecked);
    final lexicon = voice.accent == KokoroAccent.british ? 'lexicon-gb-en.txt' : 'lexicon-us-en.txt';
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn(
          _workerMain, _WorkerArgs(ready.sendPort, modelDir, lexicon, numThreads),
          onExit: ready.sendPort, onError: ready.sendPort, debugName: 'kokoro_tts');
      final reply = await ready.first;
      if (reply is _Ready) return SherpaKokoroBackend._(reply.port, isolate, reply.sampleRate);
      isolate.kill(priority: Isolate.immediate);
      throw StateError('kokoro_load_failed $reply');
    } finally {
      ready.close();
    }
  }

  @override
  Future<Float32List> synth(String sentence, KokoroVoice voice) async {
    if (_disposed) throw StateError('kokoro_closed');
    final answer = ReceivePort();
    try {
      _worker.send(_Job(sentence, voice.sid, answer.sendPort));
      final reply = await answer.first.timeout(synthTimeout,
          onTimeout: () => throw StateError('kokoro_timeout'));
      if (reply is TransferableTypedData) return reply.materialize().asFloat32List();
      throw StateError('kokoro_synth_failed $reply');
    } finally {
      answer.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _worker.send(const _Dispose());
    // Give the worker a moment to free the native model, then make sure it ends.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _WorkerArgs {
  const _WorkerArgs(this.reply, this.modelDir, this.lexicon, this.numThreads);
  final SendPort reply;
  final String modelDir;
  final String lexicon;
  final int numThreads;
}

class _Ready {
  const _Ready(this.port, this.sampleRate);
  final SendPort port;
  final int sampleRate;
}

class _Job {
  const _Job(this.text, this.sid, this.reply);
  final String text;
  final int sid;
  final SendPort reply;
}

class _Dispose {
  const _Dispose();
}

/// An error is sent back as its type name only, never the text.
class _Failed {
  const _Failed(this.type);
  final String type;
  @override
  String toString() => type;
}

void _workerMain(_WorkerArgs args) {
  final sherpa.OfflineTts tts;
  try {
    sherpa.initBindings(); // Per isolate (sherpa_onnx docs).
    final dir = args.modelDir;
    tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '$dir/model.onnx',
          voices: '$dir/voices.bin',
          tokens: '$dir/tokens.txt',
          lexicon: '$dir/${args.lexicon}',
        ),
        numThreads: args.numThreads,
      ),
    ));
  } catch (e) {
    args.reply.send(_Failed(e.runtimeType.toString()));
    return;
  }
  final jobs = ReceivePort();
  args.reply.send(_Ready(jobs.sendPort, tts.sampleRate));
  jobs.listen((msg) {
    if (msg is _Dispose) {
      tts.free();
      jobs.close();
      return;
    }
    if (msg is! _Job) return;
    try {
      final audio = tts.generate(text: msg.text, sid: msg.sid);
      if (audio.samples.isEmpty) {
        msg.reply.send(const _Failed('kokoro_empty_audio'));
      } else {
        msg.reply.send(TransferableTypedData.fromList([audio.samples]));
      }
    } catch (e) {
      msg.reply.send(_Failed(e.runtimeType.toString()));
    }
  });
}
