/// sherpa-onnx keyword spotting (zipformer transducer, Apache-2.0 code).
///
/// MODEL FILES ARE NOT BUNDLED. The owner downloads them; nothing here
/// fetches anything. Expected layout (file names follow the k2-fsa release
/// sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01; verify them against
/// the archive, and confirm the model package licence before release):
///
///   {app support dir}/models/kws/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01/
///     encoder-epoch-12-avg-2-chunk-16-left-64.onnx
///     decoder-epoch-12-avg-2-chunk-16-left-64.onnx
///     joiner-epoch-12-avg-2-chunk-16-left-64.onnx
///     tokens.txt
///     bpe.vocab   (if missing: `spm_export_vocab --model=bpe.model > bpe.vocab`)
///
/// The user's phrase is turned into BPE pieces at runtime by
/// [BpeKeywordEncoder], so no offline text2token step is needed.
///
/// Not yet verified on a device: spotting accuracy, boost/threshold values,
/// and CPU cost of decoding on the calling isolate.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'bpe_keyword_encoder.dart';
import 'wake_engine.dart';
import 'wake_phrase.dart';

const kwsModelName = 'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01';

class SherpaKwsModel {
  const SherpaKwsModel({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    required this.bpeVocab,
  });

  /// Default file names inside [dir] (see the library comment).
  factory SherpaKwsModel.inDir(String dir) {
    const tag = 'epoch-12-avg-2-chunk-16-left-64';
    return SherpaKwsModel(
      encoder: '$dir/encoder-$tag.onnx',
      decoder: '$dir/decoder-$tag.onnx',
      joiner: '$dir/joiner-$tag.onnx',
      tokens: '$dir/tokens.txt',
      bpeVocab: '$dir/bpe.vocab',
    );
  }

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final String bpeVocab;

  List<String> get files => [encoder, decoder, joiner, tokens, bpeVocab];

  /// Files that are not present on disk.
  List<String> missing() => files.where((f) => !File(f).existsSync()).toList();
}

class SherpaWakeEngine implements WakeEngine {
  /// [openAudio] returns 16-bit little-endian mono PCM at [sampleRate]; it is
  /// subscribed on [start] and cancelled on [stop].
  SherpaWakeEngine({
    required this.model,
    required this.openAudio,
    this.sampleRate = 16000,
    this.boost = 1.5,
    this.threshold = 0.25,
    this.numThreads = 1,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SherpaKwsModel model;
  final int sampleRate;
  final double boost;
  final double threshold;
  final int numThreads;
  final Stream<Uint8List> Function() openAudio;
  final DateTime Function() _clock;

  static bool _bindingsReady = false;

  final _events = StreamController<WakeEvent>.broadcast();
  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  StreamSubscription<Uint8List>? _audio;
  List<WakePhrase> _keywords = const [];

  @override
  Stream<WakeEvent> get events => _events.stream;

  @override
  bool get isRunning => _spotter != null;

  @override
  Future<void> start(List<WakePhrase> keywords) async {
    if (keywords.isEmpty) throw ArgumentError.value(keywords, 'keywords', 'empty');
    await stop();
    final missing = model.missing();
    if (missing.isNotEmpty) {
      throw StateError('KWS model files missing (not bundled): ${missing.join(', ')}');
    }
    final encoder = BpeKeywordEncoder.fromVocab(await File(model.bpeVocab).readAsString());
    final lines = keywords
        .map((k) => encoder.keywordLine(k, boost: boost, threshold: threshold))
        .join('\n');

    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }
    final spotter = sherpa.KeywordSpotter(sherpa.KeywordSpotterConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: model.encoder,
          decoder: model.decoder,
          joiner: model.joiner,
        ),
        tokens: model.tokens,
        numThreads: numThreads,
        debug: false,
      ),
      keywordsThreshold: threshold,
      keywordsScore: boost,
      keywordsBuf: lines,
      keywordsBufSize: utf8.encode(lines).length,
    ));
    _spotter = spotter;
    _stream = spotter.createStream();
    _keywords = List.unmodifiable(keywords);
    _audio = openAudio().listen(_onAudio);
  }

  void _onAudio(Uint8List pcm) {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) return;
    stream.acceptWaveform(samples: pcm16ToFloat32(pcm), sampleRate: sampleRate);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      final heard = spotter.getResult(stream).keyword;
      if (heard.isEmpty) continue;
      spotter.reset(stream);
      for (final k in _keywords) {
        if (k.matches(heard)) {
          _events.add(WakeEvent(k.text, _clock()));
          break;
        }
      }
    }
  }

  @override
  Future<void> stop() async {
    await _audio?.cancel();
    _audio = null;
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

/// 16-bit little-endian PCM to float samples in [-1, 1). An odd trailing
/// byte is dropped.
Float32List pcm16ToFloat32(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final out = Float32List(pcm.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
