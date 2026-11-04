/// Kokoro behind [TtsEngine]. [SpeechOutput] feeds it one sentence at a time:
/// [prepare] synthesises a sentence to 16-bit PCM, [play] hands it to a
/// [PcmPlayer]. The backend loads on first use (or via [load]). Never logs text.
///
/// Status: build it with buildKokoroSpeech (kokoro_factory.dart), which pairs
/// the sherpa-onnx backend with AudioTrackPlayer behind the licence gate.
/// Not verified on a device.
library;

import 'dart:typed_data';

import '../tts_engine.dart';
import 'kokoro_voices.dart';
import 'sherpa_backend.dart';
import 'synth_backend.dart';

export 'kokoro_voices.dart' show defaultKokoroVoice, kokoroEnglishVoices;

/// Kokoro's published output rate; used until the backend reports its own.
const kokoroDefaultSampleRate = 24000;

class KokoroSpeech extends PreparedSpeech {
  const KokoroSpeech(this.pcm16, this.sampleRate);
  final Int16List pcm16;
  final int sampleRate;
}

class KokoroTtsEngine implements TtsEngine {
  /// Throws [ArgumentError] when [voice] is not an English Kokoro voice.
  KokoroTtsEngine(
    this.modelDir, {
    String voice = defaultKokoroVoice,
    required this.player,
    SynthBackendLoader? loader,
  }) : voice = kokoroVoice(voice),
       _loader = loader ?? SherpaKokoroBackend.load;

  final String modelDir;
  final KokoroVoice voice;
  final PcmPlayer player;
  final SynthBackendLoader _loader;
  Future<SynthBackend>? _backend;
  int? _rate;
  bool _disposed = false;

  @override
  String get voiceId => voice.name;

  @override
  int get sampleRate => _rate ?? kokoroDefaultSampleRate;

  /// Loads the backend now. Rethrows load errors (for example
  /// KokoroLicenceRefused); a later call retries.
  Future<void> load() => _ensure();

  Future<SynthBackend> _ensure() async {
    if (_disposed) throw StateError('kokoro_disposed');
    try {
      final b = await (_backend ??= _loader(modelDir, voice));
      _rate = b.sampleRate;
      return b;
    } catch (_) {
      _backend = null;
      rethrow;
    }
  }

  @override
  Future<PreparedSpeech> prepare(String sentence) async {
    final b = await _ensure();
    return KokoroSpeech(toPcm16(await b.synth(sentence, voice)), b.sampleRate);
  }

  @override
  Future<void> play(PreparedSpeech speech) {
    final s = speech as KokoroSpeech;
    return player.play(s.pcm16, s.sampleRate);
  }

  /// Barge-in: cuts the player at once; the pending play completes.
  @override
  Future<void> stop() => player.stop();

  /// Releases the player (stopping any audio), then the backend. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final b = _backend;
    _backend = null;
    try {
      await player.dispose();
    } finally {
      if (b != null) await _release(b);
    }
  }

  /// A backend that failed to load has nothing to release.
  static Future<void> _release(Future<SynthBackend> b) async {
    final SynthBackend loaded;
    try {
      loaded = await b;
    } catch (_) {
      return;
    }
    await loaded.dispose();
  }
}
