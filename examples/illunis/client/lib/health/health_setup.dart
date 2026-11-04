/// Asks by voice before the Health Connect permission sheet: once after the
/// earlier setup questions, and again whenever the user says "connect
/// Health Connect" or "read my health data". "Yes" opens the system sheet;
/// anything else, or a no, leaves it off. The asked flag lives under
/// [StoreKeys.healthAsked], so the question is not repeated. With
/// [HealthSetup.typed] (voice off) the prompts say "type" instead of "say".
///
/// Logs carry codes only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/persistence.dart';
import '../voice/setup_answers.dart' show normaliseAnswer, parseConfirm;
import 'health_port.dart';

abstract final class HealthPrompt {
  static const offer = 'I can read your sleep, steps and heart rate from Health Connect, '
      'to look for patterns over three weeks. They stay on this phone; only daily totals go '
      'to Illunis when you ask for the three-week analysis. Shall I ask Android for access? '
      'Say yes or no.';
  static const reask = 'Please say yes or no.';
  static const sheet = 'Android will now show what I can read. Choose allow to continue.';
  static const granted = 'Thank you. I can read your sleep, steps and heart rate now.';
  static const partial = 'Thank you. Some of it is allowed; I will use what I can read.';
  static const denied = 'All right, I will not read Health Connect. Say connect Health Connect any time.';
  static const declined = 'All right. Say connect Health Connect if you change your mind.';
  static const unavailable = 'Health Connect is not available on this phone.';
  static const update = 'Health Connect needs an update from the Play Store first.';
}

/// Typed prompts (voice off) where the spoken ones say "say"; the rest of
/// [HealthPrompt] is shared.
abstract final class TypedHealthPrompt {
  static const offer = 'I can read your sleep, steps and heart rate from Health Connect, '
      'to look for patterns over three weeks. They stay on this phone; only daily totals go '
      'to Illunis when you ask for the three-week analysis. Shall I ask Android for access? '
      'Type yes or no.';
  static const reask = 'Please type yes or no.';
  static const denied = 'All right, I will not read Health Connect. Type connect Health Connect any time.';
  static const declined = 'All right. Type connect Health Connect if you change your mind.';
}

final _intent = RegExp(
    r'^(?:please )?(?:connect|use|link|turn on|enable|allow)(?: to)? (?:my )?(?:health connect|health data|health)'
    r'|^(?:please )?read my (?:health|sleep|steps|heart rate)(?: data)?');

/// True for "connect Health Connect", "use my health data", "read my sleep".
bool isHealthIntent(String raw) => _intent.hasMatch(normaliseAnswer(raw));

class HealthSetup {
  HealthSetup({
    required this.port,
    required this.store,
    required this.speak,
    this.listen,
    bool Function()? ready,
    this.typed = false,
    void Function(String line)? log,
  })  : _ready = ready ?? (() => true),
        _log = log ?? debugPrint;

  final HealthPort port;
  final StateStore store;
  final Future<void> Function(String text) speak;
  final void Function()? listen;
  final bool Function() _ready;

  /// Typed wording (voice off): see the library comment.
  final bool typed;
  final void Function(String) _log;

  bool _asked = false;
  bool _asking = false;
  Future<void> _queue = Future.value();

  bool get asked => _asked;
  bool get asking => _asking;
  Future<void> get settled => _queue;

  Future<void> load() async => _asked = await store.getBool(StoreKeys.healthAsked) ?? false;

  /// Asks once, when ready, Health Connect is present and access is missing.
  Future<void> offer() {
    _queue = _queue.then((_) => _guard(() async {
          if (_asking || _asked || !_ready()) return;
          if (await port.availability() != HealthAvailability.available) return;
          if (await port.hasPermissions()) return _markAsked();
          await _begin();
        }));
    return _queue;
  }

  bool claim(String text) {
    if (!_ready()) return false;
    final intent = isHealthIntent(text);
    if (!_asking && !intent) return false;
    _queue = _queue.then((_) => _guard(() => intent && !_asking ? _fromIntent() : _answer(text)));
    return true;
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      _asking = false;
      _log('health: setup_failed error=${e.runtimeType}');
    }
  }

  Future<void> _fromIntent() async {
    switch (await port.availability()) {
      case HealthAvailability.available:
        if (await port.hasPermissions()) return speak(HealthPrompt.granted);
        return _begin();
      case HealthAvailability.updateRequired:
        return speak(HealthPrompt.update);
      case HealthAvailability.notInstalled || HealthAvailability.unsupported:
        return speak(HealthPrompt.unavailable);
    }
  }

  Future<void> _begin() async {
    _asking = true;
    await speak(typed ? TypedHealthPrompt.offer : HealthPrompt.offer);
    if (_asking) listen?.call();
  }

  Future<void> _answer(String text) async {
    final a = parseConfirm(text);
    if (a == null) {
      _log('health: reask');
      await speak(typed ? TypedHealthPrompt.reask : HealthPrompt.reask);
      if (_asking) listen?.call();
      return;
    }
    _asking = false;
    await _markAsked();
    if (!a.yes) {
      _log('health: declined');
      return speak(typed ? TypedHealthPrompt.declined : HealthPrompt.declined);
    }
    await speak(HealthPrompt.sheet);
    final r = await port.requestPermissions();
    _log('health: permission=${r.name}');
    await speak(switch (r) {
      HealthPermission.granted => HealthPrompt.granted,
      HealthPermission.partial => HealthPrompt.partial,
      HealthPermission.denied => typed ? TypedHealthPrompt.denied : HealthPrompt.denied,
      HealthPermission.unavailable => HealthPrompt.unavailable,
    });
  }

  Future<void> _markAsked() async {
    _asked = true;
    await store.setBool(StoreKeys.healthAsked, true);
  }
}
