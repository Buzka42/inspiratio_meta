/// Microphone to voice session: capture feeds the wake word engine; a wake
/// (or any StartListening command, such as after the alarm digest) opens a
/// speech-to-text session whose final transcript goes through the voice
/// reducer to [AppController.handleUtterance]. The session closes when the
/// voice state returns to idle. Logs carry codes only, never audio or text.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/app_controller.dart';
import '../voice/voice_session.dart';
import '../voice/wake_keyword.dart';
import 'input_ports.dart';

enum InputStatus { off, starting, running, denied, failed, disposed }

typedef InputLog = void Function(String message);

class InputPipeline {
  InputPipeline({
    required this.controller,
    required this.permission,
    required this.capture,
    required this.wakeWord,
    required this.stt,
    required this.keyword,
    InputLog? log,
  }) : _log = log ?? debugPrint;

  final AppController controller;
  final MicPermissionPort permission;
  final AudioCapturePort capture;
  final WakeWordPort wakeWord;
  final SpeechToTextPort stt;

  /// The user's wake keyword, or null before the interview sets it (then only
  /// StartListening commands open a session).
  final WakeKeyword? Function() keyword;
  final InputLog _log;

  InputStatus _status = InputStatus.off;
  String? _errorCode;

  final _fan = StreamController<Uint8List>.broadcast(sync: true);
  StreamSubscription<Uint8List>? _captureSub;
  StreamSubscription<WakeWordHeard>? _wakeSub;
  StreamSubscription<Utterance>? _sttSub;
  StreamSubscription<void>? _listenSub;

  InputStatus get status => _status;

  /// Last failure code: mic_denied, mic_unavailable, mic_start_failed,
  /// wake_failed or stt_failed.
  String? get errorCode => _errorCode;
  bool get sessionOpen => _sttSub != null;

  /// Asks for the microphone and starts wake word spotting. Returns false
  /// (and sets [errorCode]) when the mic is denied or fails; never throws.
  Future<bool> start() async {
    if (_status == InputStatus.running || _status == InputStatus.starting) return true;
    if (_status == InputStatus.disposed) return false;
    _status = InputStatus.starting;
    _errorCode = null;

    MicPermission p;
    try {
      p = await permission.request();
    } catch (_) {
      p = MicPermission.unavailable;
    }
    if (_status != InputStatus.starting) return false; // Stopped meanwhile.
    if (p != MicPermission.granted) {
      return _fail(p == MicPermission.denied ? 'mic_denied' : 'mic_unavailable',
          InputStatus.denied);
    }

    try {
      _captureSub = capture.chunks.listen(_fan.add);
      await capture.start();
    } catch (e) {
      await _captureSub?.cancel();
      _captureSub = null;
      return _fail('mic_start_failed', InputStatus.failed, e);
    }
    if (_status != InputStatus.starting) {
      await _stopCapture();
      return false;
    }

    _status = InputStatus.running;
    _listenSub = controller.listenRequests.listen((_) => _openSession());
    controller.addListener(_onVoice);
    _startWake();
    if (controller.voice == VoiceState.listening) _openSession();
    return true;
  }

  /// Restarts spotting with the current [keyword] (call after the interview
  /// sets or changes it).
  void refreshKeyword() {
    if (_status != InputStatus.running) return;
    _wakeSub?.cancel();
    _wakeSub = null;
    _startWake();
  }

  void _startWake() {
    final kw = keyword();
    if (kw == null) {
      _log('input: wake_off reason=no_keyword');
      return;
    }
    _wakeSub = wakeWord
        .listen(_fan.stream, kw, sampleRate: capture.sampleRate)
        .listen((_) => _onWake(), onError: (Object e) {
      _errorCode = 'wake_failed';
      _log('input: wake_failed error=${e.runtimeType}');
    });
  }

  void _onWake() {
    switch (controller.voice) {
      case VoiceState.idle:
        controller.dispatch(const WakeWordHeard());
      case VoiceState.thinking:
      case VoiceState.speaking:
        controller.dispatch(const BargeIn());
      case VoiceState.listening:
        break;
    }
  }

  void _openSession() {
    if (_status != InputStatus.running || _sttSub != null) return;
    _sttSub = stt
        .transcribe(_fan.stream, sampleRate: capture.sampleRate)
        .listen(_onUtterance, onError: (Object e) {
      _errorCode = 'stt_failed';
      _log('input: stt_failed error=${e.runtimeType}');
      _closeSession();
      if (controller.voice == VoiceState.listening) {
        controller.dispatch(const UserSpeechEnded('')); // Back to idle.
      }
    });
  }

  void _onUtterance(Utterance u) {
    final text = u.text.trim();
    final voice = controller.voice;
    if (voice == VoiceState.speaking || voice == VoiceState.thinking) {
      if (text.isEmpty) return;
      controller.dispatch(const BargeIn()); // Now listening.
    }
    if (u.isFinal && controller.voice == VoiceState.listening) {
      // An empty final (no speech before the endpoint) returns to idle.
      controller.dispatch(UserSpeechEnded(text));
    }
  }

  void _onVoice() {
    if (controller.voice == VoiceState.idle) _closeSession();
  }

  void _closeSession() {
    final s = _sttSub;
    _sttSub = null;
    s?.cancel();
  }

  bool _fail(String code, InputStatus status, [Object? e]) {
    _errorCode = code;
    _status = status;
    _log(e == null ? 'input: $code' : 'input: $code error=${e.runtimeType}');
    return false;
  }

  Future<void> _stopCapture() async {
    await _captureSub?.cancel();
    _captureSub = null;
    try {
      await capture.stop();
    } catch (e) {
      _log('input: mic_stop_failed error=${e.runtimeType}');
    }
  }

  /// Ends spotting and any session and stops the microphone.
  Future<void> stop() async {
    final wasActive =
        _status == InputStatus.running || _status == InputStatus.starting;
    _status = InputStatus.off;
    if (!wasActive) return;
    controller.removeListener(_onVoice);
    await _listenSub?.cancel();
    _listenSub = null;
    _closeSession();
    await _wakeSub?.cancel();
    _wakeSub = null;
    await _stopCapture();
  }

  Future<void> dispose() async {
    if (_status == InputStatus.disposed) return;
    await stop();
    _status = InputStatus.disposed;
    await _fan.close();
  }
}
