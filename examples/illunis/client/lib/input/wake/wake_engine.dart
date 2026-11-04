/// Keyword-spotting port. Engines are swappable: [FakeWakeEngine] for tests,
/// [SherpaWakeEngine] for sherpa-onnx zipformer KWS on device.
library;

import 'wake_phrase.dart';

/// One spotted keyword. [keyword] is the normalised phrase that was heard.
class WakeEvent {
  const WakeEvent(this.keyword, this.time);

  final String keyword;
  final DateTime time;

  @override
  bool operator ==(Object other) =>
      other is WakeEvent && other.keyword == keyword && other.time == time;

  @override
  int get hashCode => Object.hash(keyword, time);

  @override
  String toString() => 'WakeEvent($keyword, $time)';
}

abstract class WakeEngine {
  /// Raw spotter output (not debounced; see wake_debounce.dart). Broadcast,
  /// so it may be listened to before [start] and across restarts.
  Stream<WakeEvent> get events;

  bool get isRunning;

  /// Starts spotting [keywords]. Calling it while running replaces the
  /// keyword set. Throws [ArgumentError] when [keywords] is empty.
  Future<void> start(List<WakePhrase> keywords);

  /// Stops spotting and releases engine resources. Safe to call twice.
  Future<void> stop();
}
