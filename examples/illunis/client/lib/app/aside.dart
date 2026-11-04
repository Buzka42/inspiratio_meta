/// Shared seams for the voice flows (council, approval, assistant,
/// inbox): how they speak, listen, show a caption and wait, all injectable
/// so tests run without a device or real time.
library;

import 'dart:async';

import 'server_port.dart';

/// Speaks text outside a voice turn; true when every sentence played
/// (AppController.speakAside).
typedef AsideSpeak = Future<bool> Function(String text);

/// Shows a caption without speaking (AppController.showCaption).
typedef AsideCaption = void Function(String text);

/// Opens a listening session for an answer (the app dispatches
/// WakeWordHeard when the microphone runs).
typedef AsideListen = void Function();

typedef AsideLog = void Function(String line);

/// A cancellable one-shot timer. Tests pass a fake that fires by hand.
typedef OneShotTimer = Timer Function(Duration after, void Function() fire);

Timer realTimer(Duration after, void Function() fire) => Timer(after, fire);

/// Waits until [quiet] holds, checking every [step], at most [limit].
/// True when it became quiet in time.
Future<bool> waitForQuiet(bool Function() quiet,
    {Duration step = const Duration(milliseconds: 300), Duration limit = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(limit);
  while (!quiet()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(step);
  }
  return true;
}

/// A fixed error code for logs: server codes pass when they look like
/// codes, everything else is its type name. Never a message or payload.
String asideCode(Object e) {
  if (e is TimeoutException) return 'timeout';
  final c = e is ServerException ? e.error : null;
  if (c != null && RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(c)) return c;
  return e.runtimeType.toString();
}
