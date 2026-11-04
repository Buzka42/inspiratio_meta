// Fakes for the voice flow tests: a hand-fired timer and a recording speaker.
// Synthetic data only.
import 'dart:async';

class FakeTimer implements Timer {
  FakeTimer(this.after, this._fire);
  final Duration after;
  final void Function() _fire;
  bool cancelled = false, fired = false;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    _fire();
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => fired ? 1 : 0;
}

class FakeTimers {
  final all = <FakeTimer>[];

  Timer call(Duration after, void Function() fire) {
    final t = FakeTimer(after, fire);
    all.add(t);
    return t;
  }

  Iterable<FakeTimer> get active => all.where((t) => t.isActive);

  /// Fires every active timer once (timers they arm are left for later).
  void fireActive() {
    for (final t in active.toList()) {
      t.fire();
    }
  }
}

class Speaker {
  final spoken = <String>[];
  final captions = <String>[];

  /// The next speak() calls return these (true when the list runs out).
  final results = <bool>[];

  Future<bool> speak(String text) async {
    spoken.add(text);
    return results.isEmpty ? true : results.removeAt(0);
  }

  void caption(String text) => captions.add(text);
}

/// Lets queued futures and microtasks run.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
