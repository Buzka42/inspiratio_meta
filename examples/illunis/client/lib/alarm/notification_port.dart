/// Posts the digest notification and reports taps. The tap opens the app
/// (native content intent) and is the user action that may start the mic.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'alarm_settings.dart';

abstract class NotificationPort {
  /// [payloadId] is an opaque id (for example `morning_digest`), never text.
  Future<void> show({required String title, required String body, required String payloadId});

  /// Payload ids of taps that arrive while the app is running.
  Stream<String> get onTap;

  /// Payload id of the tap that launched the app, or null. Read once at start.
  Future<String?> launchPayload();
}

class ShownNotification {
  const ShownNotification(this.title, this.body, this.payloadId);
  final String title, body, payloadId;
}

/// In-memory notifications for tests. [tap] simulates the user's tap.
class FakeNotificationPort implements NotificationPort {
  FakeNotificationPort({this.launchedWith});

  final shown = <ShownNotification>[];
  String? launchedWith;
  final _taps = StreamController<String>.broadcast(sync: true);

  @override
  Future<void> show({required String title, required String body, required String payloadId}) async =>
      shown.add(ShownNotification(title, body, payloadId));

  @override
  Stream<String> get onTap => _taps.stream;

  @override
  Future<String?> launchPayload() async {
    final p = launchedWith;
    launchedWith = null;
    return p;
  }

  void tap(String payloadId) => _taps.add(payloadId);

  Future<void> close() => _taps.close();
}

/// Platform contract for the native side (NotificationHandler.kt).
abstract final class NotificationChannel {
  static const name = 'illunis/notifications';

  /// Dart to native: `{title, body, payload_id}`. Needs POST_NOTIFICATIONS
  /// (Android 13+) and a high-importance channel; the content intent opens
  /// MainActivity with the payload id as an extra.
  static const show = 'show';

  /// Dart to native: returns the launching payload id or null, then clears it.
  static const launchPayload = 'getLaunchPayload';

  /// Native to Dart: `{payload_id}` when a tap arrives while running.
  /// Returns true when delivered; otherwise native keeps it as the launch
  /// payload.
  static const onTap = 'onNotificationTap';
}

/// Talks to NotificationHandler.kt. Without it (tests, other platforms) every
/// call fails with MissingPluginException, which is logged by code only.
class MethodChannelNotificationPort implements NotificationPort {
  MethodChannelNotificationPort({MethodChannel? channel, AlarmLog? log})
      : _ch = channel ?? const MethodChannel(NotificationChannel.name),
        _log = log ?? debugPrint {
    // Answers whether the tap was delivered. False (no listener yet, at a
    // cold start) makes native keep it for [launchPayload].
    _ch.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (call.method != NotificationChannel.onTap || args is! Map || args['payload_id'] is! String) {
        return false;
      }
      if (!_taps.hasListener) return false;
      _taps.add(args['payload_id'] as String);
      return true;
    });
  }

  final MethodChannel _ch;
  final AlarmLog _log;
  final _taps = StreamController<String>.broadcast();

  @override
  Future<void> show({required String title, required String body, required String payloadId}) async {
    try {
      await _ch.invokeMethod<void>(
          NotificationChannel.show, {'title': title, 'body': body, 'payload_id': payloadId});
    } catch (e) {
      _log('notify: show_failed error=${e.runtimeType}');
    }
  }

  @override
  Stream<String> get onTap => _taps.stream;

  @override
  Future<String?> launchPayload() async {
    try {
      return await _ch.invokeMethod<String>(NotificationChannel.launchPayload);
    } catch (e) {
      _log('notify: launch_payload_failed error=${e.runtimeType}');
      return null;
    }
  }
}
