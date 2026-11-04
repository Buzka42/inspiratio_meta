/// The Whisper decode behind [SherpaWhisperStt]. The sherpa-onnx calls
/// (model load, acceptWaveform, decode) are blocking FFI, so they run on one
/// long-lived worker isolate: the model loads once, each utterance is sent
/// over as transferable float samples and the text comes back. The UI
/// isolate never blocks on native code.
///
/// Not verified on a device: load time, time per utterance, and memory.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'whisper_model.dart';

/// Turns one finished utterance (mono float samples in [-1, 1)) into text.
/// The seam for fakes in tests.
abstract class WhisperRecogniser {
  Future<String> recognise(Float32List samples, int sampleRate);
  Future<void> dispose();
}

/// Failure codes. Logged as codes only; messages never carry audio or text.
class WhisperFailure implements Exception {
  const WhisperFailure(this.code, [this.detail = '']);
  final String code;
  final String detail;

  @override
  String toString() => detail.isEmpty ? 'WhisperFailure($code)' : 'WhisperFailure($code: $detail)';
}

const sttModelMissing = 'stt_model_missing';
const sttLoadFailed = 'stt_load_failed';
const sttDecodeFailed = 'stt_decode_failed';
const sttClosed = 'stt_closed';

/// sherpa-onnx OfflineRecognizer on a worker isolate.
class IsolateWhisperRecogniser implements WhisperRecogniser {
  IsolateWhisperRecogniser(this.model,
      {this.numThreads = 2,
      this.decodeTimeout = const Duration(seconds: 60),
      this.nativeLibDir});

  final WhisperModel model;
  final int numThreads;

  /// A decode that takes longer than this fails with [sttDecodeFailed]. The
  /// gate caps an utterance at 15 s and eval/stt measured RTF ~0.5, so this
  /// only catches a stuck worker.
  final Duration decodeTimeout;

  /// Directory of the sherpa-onnx native library. Null (the app) lets
  /// sherpa resolve it; host tests pass the pub-cache path, as eval/stt does.
  final String? nativeLibDir;

  Future<SendPort>? _worker;
  Isolate? _isolate;
  bool _disposed = false;

  /// Starts the isolate and loads the model now, so the first utterance does
  /// not pay the load (about 1 s on Linux, eval/stt). Errors are kept for the
  /// next [recognise].
  void warmUp() => unawaited(_start().then((_) {}, onError: (_) {}));

  Future<SendPort> _start() => _worker ??= _spawn();

  Future<SendPort> _spawn() async {
    final ready = ReceivePort();
    try {
      _isolate = await Isolate.spawn(_workerMain,
          _WorkerArgs(
              ready.sendPort, model.encoder, model.decoder, model.tokens, numThreads, nativeLibDir),
          // A worker that dies before it is ready answers null or an error list.
          onExit: ready.sendPort,
          onError: ready.sendPort,
          debugName: 'whisper_stt');
      final reply = await ready.first;
      if (reply is SendPort) return reply;
      throw WhisperFailure(sttLoadFailed, '$reply');
    } on WhisperFailure {
      rethrow;
    } catch (e) {
      throw WhisperFailure(sttLoadFailed, e.runtimeType.toString());
    } finally {
      ready.close();
    }
  }

  @override
  Future<String> recognise(Float32List samples, int sampleRate) async {
    if (_disposed) throw const WhisperFailure(sttClosed);
    final worker = await _start();
    final answer = ReceivePort();
    try {
      worker.send(_Job(TransferableTypedData.fromList([samples]), sampleRate, answer.sendPort));
      final reply = await answer.first.timeout(decodeTimeout,
          onTimeout: () => throw const WhisperFailure(sttDecodeFailed, 'timeout'));
      if (reply is String) return reply;
      throw WhisperFailure(sttDecodeFailed, '$reply');
    } finally {
      answer.close();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class _WorkerArgs {
  const _WorkerArgs(
      this.reply, this.encoder, this.decoder, this.tokens, this.numThreads, this.nativeLibDir);
  final SendPort reply;
  final String encoder;
  final String decoder;
  final String tokens;
  final int numThreads;
  final String? nativeLibDir;
}

class _Job {
  const _Job(this.samples, this.sampleRate, this.reply);
  final TransferableTypedData samples;
  final int sampleRate;
  final SendPort reply;
}

/// A decode error is sent back as a non-String (its type name only).
class _Failed {
  const _Failed(this.type);
  final String type;
  @override
  String toString() => type;
}

void _workerMain(_WorkerArgs args) {
  final sherpa.OfflineRecognizer recognizer;
  try {
    sherpa.initBindings(args.nativeLibDir); // Per isolate (sherpa_onnx docs).
    recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: args.encoder,
          decoder: args.decoder,
          language: 'en',
          task: 'transcribe',
        ),
        tokens: args.tokens,
        numThreads: args.numThreads,
        debug: false,
      ),
    ));
  } catch (e) {
    args.reply.send(_Failed(e.runtimeType.toString()));
    return;
  }
  final jobs = ReceivePort();
  args.reply.send(jobs.sendPort);
  jobs.listen((message) {
    if (message is! _Job) return;
    sherpa.OfflineStream? stream;
    try {
      final samples = message.samples.materialize().asFloat32List();
      stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: message.sampleRate);
      recognizer.decode(stream);
      message.reply.send(recognizer.getResult(stream).text.trim());
    } catch (e) {
      message.reply.send(_Failed(e.runtimeType.toString()));
    } finally {
      stream?.free();
    }
  });
}
