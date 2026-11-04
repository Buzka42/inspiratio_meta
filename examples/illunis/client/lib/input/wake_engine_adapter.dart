/// Wires a [WakeEngine] (sherpa-onnx KWS, 2-4 word phrase) into the existing
/// [WakeWordPort], behind a switch: [selectWakeWordPort] keeps the old
/// single-word port unless a valid engine phrase is set. When the engine
/// cannot start (model files missing), the adapter reports
/// [wakeEngineUnavailable] and spots with the old port instead. Logs carry
/// codes only, never audio or text.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../voice/voice_session.dart';
import '../voice/wake_keyword.dart';
import 'input_ports.dart';
import 'wake/wake_debounce.dart';
import 'wake/wake_engine.dart';
import 'wake/wake_phrase.dart';

/// Error code when the engine's start throws.
const wakeEngineUnavailable = 'wake_engine_unavailable';

/// The engine phrase for [raw], or null when unset or rejected by
/// wake_phrase validation. Pure.
WakePhrase? engineWakePhrase(String? raw) =>
    raw == null ? null : WakePhrase.tryCreate(raw);

/// The switch. Returns [legacy] (the old single-word rule, the default)
/// unless [enginePhrase] is a valid wake phrase; then the port built by
/// [buildEngine] for it. Pure: [buildEngine] is only called when chosen.
WakeWordPort selectWakeWordPort({
  required WakeWordPort legacy,
  required String? enginePhrase,
  required WakeWordPort Function(WakePhrase phrase) buildEngine,
}) {
  final phrase = engineWakePhrase(enginePhrase);
  return phrase == null ? legacy : buildEngine(phrase);
}

/// Hands the pipeline's audio to an engine that opens its own source
/// (SherpaWakeEngine.openAudio: `openAudio: relay.open`).
class WakeAudioRelay {
  Stream<Uint8List>? _audio;

  void attach(Stream<Uint8List> audio) => _audio = audio;

  Stream<Uint8List> open() => _audio ?? const Stream.empty();
}

class WakeEngineAdapter implements WakeWordPort {
  WakeEngineAdapter({
    required this.engine,
    required this.phrase,
    required this.fallback,
    this.audioRelay,
    this.window = wakeDebounce,
    void Function(String message)? log,
  }) : _log = log ?? debugPrint;

  final WakeEngine engine;
  final WakePhrase phrase;

  /// The old port, used when the engine cannot start.
  final WakeWordPort fallback;
  final WakeAudioRelay? audioRelay;
  final Duration window;
  final void Function(String message) _log;

  String? _errorCode;
  bool _usingFallback = false;
  DateTime? _lastAccepted; // Kept across restarts so a restart cannot double-wake.
  Future<void> _idle = Future.value(); // Serialises engine start and stop.

  /// [wakeEngineUnavailable] after a failed start, else null.
  String? get errorCode => _errorCode;

  /// True while the last listen fell back to [fallback].
  bool get usingFallback => _usingFallback;

  @override
  Stream<WakeWordHeard> listen(Stream<Uint8List> audio, WakeKeyword keyword,
      {required int sampleRate}) {
    late final StreamController<WakeWordHeard> out;
    StreamSubscription<Object?>? sub;
    var active = true;

    Future<void> open() async {
      audioRelay?.attach(audio);
      final events = engine.events.listen((e) {
        if (!phrase.matches(e.keyword) || !acceptWake(_lastAccepted, e.time, window: window)) {
          return;
        }
        _lastAccepted = e.time;
        out.add(const WakeWordHeard());
      });
      try {
        await engine.start([phrase]);
      } catch (e) {
        await events.cancel();
        if (!active) return;
        _errorCode = wakeEngineUnavailable;
        _usingFallback = true;
        _log('input: $wakeEngineUnavailable error=${e.runtimeType}');
        sub = fallback
            .listen(audio, keyword, sampleRate: sampleRate)
            .listen(out.add, onError: out.addError);
        return;
      }
      if (!active) {
        await events.cancel();
        await engine.stop();
        return;
      }
      _errorCode = null;
      _usingFallback = false;
      sub = events;
    }

    Future<void> close() async {
      final s = sub;
      sub = null;
      await s?.cancel();
      await engine.stop();
    }

    void chain(Future<void> Function() step) => _idle = _idle.then((_) => step()).catchError(
        (Object e) => _log('input: wake_engine_failed error=${e.runtimeType}'));

    out = StreamController<WakeWordHeard>(
      sync: true,
      onListen: () => chain(open),
      onCancel: () {
        active = false;
        chain(close);
        return _idle;
      },
    );
    return out.stream;
  }
}
