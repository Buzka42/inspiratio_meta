/// Local key-value persistence. On-device only; no network.
///
/// [SharedPrefsStore] is the device store. [GuardedStore] wraps any store so
/// every read and write is caught: reads fall back to null, writes are
/// dropped, and the log line names only the operation, the key and the error
/// type, never a value. [persistentStore] returns the guarded device store.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fog_settings.dart';

/// Keys written by the app. The memory and health keys hold the user's own
/// notes, summaries, check-ins and daily signals; they stay in this private
/// store and are never logged.
abstract final class StoreKeys {
  static const fog = FogSettings.key;
  static const digestLastFired = 'digest_last_fired';
  static const interview = 'interview_state';
  static const voiceSetup = 'voice_setup_draft';
  static const memoryMode = 'memory_mode';
  static const shortTermMemory = 'memory_short_term';
  static const longTermMemory = 'memory_long_term';
  static const checkIns = 'health_checkins';
  static const healthAsked = 'health_asked';
  static const assistantInbox = 'assistant_inbox';
  static const analysisLastRun = 'analysis_last_run';

  /// The last GET /spec version seen; a newer one adds a chat line.
  static const specVersion = 'spec_version';

  /// The typed chat thread (app/chat_thread.dart): the user's own words and
  /// the replies. Private, never logged.
  static const chatThread = 'chat_thread';

  /// Structured logs (logs/log_store.dart): on the phone only, never sent
  /// to memory or logged.
  static const logs = 'logs_local';
}

/// [KeyValueStore] with strings, used for dates and the interview JSON.
abstract class StateStore implements KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// For tests and as a stand-in. Lost on restart unless the instance is shared.
class InMemoryStateStore implements StateStore {
  final _m = <String, Object>{};

  @override
  Future<bool?> getBool(String key) async => _m[key] is bool ? _m[key] as bool : null;
  @override
  Future<void> setBool(String key, bool value) async => _m[key] = value;
  @override
  Future<String?> getString(String key) async => _m[key] is String ? _m[key] as String : null;
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

/// Backed by the shared_preferences plugin (app-private storage on Android).
/// Errors propagate; wrap it in [GuardedStore].
class SharedPrefsStore implements StateStore {
  SharedPrefsStore({Future<SharedPreferences> Function()? open})
      : _open = open ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _open;
  Future<SharedPreferences>? _prefs;

  /// Retries the open after a failure instead of caching the error.
  Future<SharedPreferences> _p() async {
    final f = _prefs ??= _open();
    try {
      return await f;
    } catch (_) {
      _prefs = null;
      rethrow;
    }
  }

  @override
  Future<bool?> getBool(String key) async => (await _p()).getBool(key);
  @override
  Future<void> setBool(String key, bool value) async {
    if (!await (await _p()).setBool(key, value)) throw StateError('write refused');
  }

  @override
  Future<String?> getString(String key) async => (await _p()).getString(key);
  @override
  Future<void> setString(String key, String value) async {
    if (!await (await _p()).setString(key, value)) throw StateError('write refused');
  }

  @override
  Future<void> remove(String key) async => (await _p()).remove(key);
}

typedef StoreLog = void Function(String line);

/// Catches every failure of [inner]. Logs `op key ErrorType` only.
class GuardedStore implements StateStore {
  GuardedStore(this.inner, {StoreLog? log}) : _log = log ?? debugPrint;

  final StateStore inner;
  final StoreLog _log;

  Future<T?> _guard<T>(String op, String key, Future<T?> Function() f) async {
    try {
      return await f();
    } catch (e) {
      _log('persistence: $op failed key=$key error=${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<bool?> getBool(String key) => _guard('read', key, () => inner.getBool(key));
  @override
  Future<void> setBool(String key, bool value) =>
      _guard('write', key, () => inner.setBool(key, value));
  @override
  Future<String?> getString(String key) => _guard('read', key, () => inner.getString(key));
  @override
  Future<void> setString(String key, String value) =>
      _guard('write', key, () => inner.setString(key, value));
  @override
  Future<void> remove(String key) => _guard('remove', key, () => inner.remove(key));
}

/// The app's store: shared_preferences behind the guard.
StateStore persistentStore({StoreLog? log}) => GuardedStore(SharedPrefsStore(), log: log);
