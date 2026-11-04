/// Minimal async key-value store. Swap for SharedPreferences in the app.
abstract class KeyValueStore {
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
}

class InMemoryKeyValueStore implements KeyValueStore {
  final _m = <String, bool>{};
  @override
  Future<bool?> getBool(String key) async => _m[key];
  @override
  Future<void> setBool(String key, bool value) async => _m[key] = value;
}

/// Fog and mist effects on or off. Default on.
class FogSettings {
  FogSettings(this._store);
  static const key = 'fog_enabled';
  final KeyValueStore _store;
  bool _enabled = true;

  bool get enabled => _enabled;

  Future<void> load() async => _enabled = await _store.getBool(key) ?? true;

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await _store.setBool(key, v);
  }
}
