/// Scripted fakes for the input ports. Synthetic data only. Every stream is
/// synchronous so tests run deterministically without timers.
library;

import 'dart:async';
import 'dart:typed_data';

import '../voice/voice_session.dart';
import '../voice/wake_keyword.dart';
import 'input_ports.dart';

class FakeMicPermission implements MicPermissionPort {
  FakeMicPermission([this.answer = MicPermission.granted]);
  MicPermission answer;
  int requests = 0;

  @override
  Future<MicPermission> request() async {
    requests++;
    return answer;
  }
}

/// Emits scripted chunks only when the test calls [emit] while capturing.
class FakeAudioCapture implements AudioCapturePort {
  FakeAudioCapture({List<Uint8List>? script, this.sampleRate = 16000})
      : _script = List.of(script ?? const []);

  final List<Uint8List> _script;
  final _out = StreamController<Uint8List>.broadcast(sync: true);

  @override
  final int sampleRate;
  bool capturing = false;
  int starts = 0;
  int stops = 0;

  @override
  Stream<Uint8List> get chunks => _out.stream;

  @override
  Future<void> start() async {
    starts++;
    capturing = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    capturing = false;
  }

  /// Emits the next [n] scripted chunks (a silent 20 ms chunk when the
  /// script runs out). Returns how many were emitted.
  int emit([int n = 1]) {
    if (!capturing) return 0;
    for (var i = 0; i < n; i++) {
      _out.add(_script.isEmpty ? Uint8List(sampleRate ~/ 25) : _script.removeAt(0));
    }
    return n;
  }
}

/// Each received chunk consumes one scripted transcript fragment; a fragment
/// the keyword matches emits [WakeWordHeard].
class FakeWakeWordPort implements WakeWordPort {
  FakeWakeWordPort(List<String> fragments) : _fragments = List.of(fragments);
  final List<String> _fragments;
  int listens = 0;

  void addFragments(Iterable<String> more) => _fragments.addAll(more);

  @override
  Stream<WakeWordHeard> listen(Stream<Uint8List> audio, WakeKeyword keyword,
      {required int sampleRate}) {
    listens++;
    late final StreamController<WakeWordHeard> out;
    StreamSubscription<Uint8List>? sub;
    out = StreamController<WakeWordHeard>(
      sync: true,
      onListen: () => sub = audio.listen((_) {
        if (_fragments.isEmpty) return;
        if (keyword.matches(_fragments.removeAt(0))) out.add(const WakeWordHeard());
      }),
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }
}

/// Each received chunk consumes one scripted utterance. The script is shared
/// across sessions, so a second session continues where the first stopped.
class FakeSpeechToText implements SpeechToTextPort {
  FakeSpeechToText(List<Utterance> script) : _script = List.of(script);
  final List<Utterance> _script;
  int sessionsOpened = 0;
  int sessionsClosed = 0;
  bool get sessionOpen => sessionsOpened > sessionsClosed;

  void addUtterances(Iterable<Utterance> more) => _script.addAll(more);

  @override
  Stream<Utterance> transcribe(Stream<Uint8List> audio, {required int sampleRate}) {
    late final StreamController<Utterance> out;
    StreamSubscription<Uint8List>? sub;
    out = StreamController<Utterance>(
      sync: true,
      onListen: () {
        sessionsOpened++;
        sub = audio.listen((_) {
          if (_script.isNotEmpty) out.add(_script.removeAt(0));
        });
      },
      onCancel: () {
        sessionsClosed++;
        return sub?.cancel();
      },
    );
    return out.stream;
  }
}
