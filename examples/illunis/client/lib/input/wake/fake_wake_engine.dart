/// Test engine: [hear] emits a wake for a phrase that is currently spotted.
library;

import 'dart:async';

import 'wake_engine.dart';
import 'wake_phrase.dart';

class FakeWakeEngine implements WakeEngine {
  FakeWakeEngine({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _events = StreamController<WakeEvent>.broadcast();
  List<WakePhrase> _keywords = const [];
  bool _running = false;

  /// Keywords passed to the last [start].
  List<WakePhrase> get keywords => _keywords;

  @override
  Stream<WakeEvent> get events => _events.stream;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start(List<WakePhrase> keywords) async {
    if (keywords.isEmpty) throw ArgumentError.value(keywords, 'keywords', 'empty');
    _keywords = List.unmodifiable(keywords);
    _running = true;
  }

  @override
  Future<void> stop() async => _running = false;

  /// Simulates the spotter hearing [spoken]. Emits and returns true only
  /// while running and when [spoken] matches a started keyword.
  bool hear(String spoken, {DateTime? at}) {
    if (!_running) return false;
    for (final k in _keywords) {
      if (k.matches(spoken)) {
        _events.add(WakeEvent(k.text, at ?? _clock()));
        return true;
      }
    }
    return false;
  }

  Future<void> dispose() => _events.close();
}
