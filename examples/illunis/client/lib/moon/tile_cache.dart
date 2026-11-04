/// Least-recently-used tile cache that never evicts tiles in view.
///
/// When every cached tile is in view the cache may hold more than
/// [capacity] until the view moves. Evicted values go to [onEvict] so the
/// renderer can dispose GPU textures.
class TileCache<V> {
  TileCache({required this.capacity, this.onEvict})
    : assert(capacity > 0, 'capacity must be positive');

  final int capacity;
  final void Function(String name, V value)? onEvict;

  // Iteration order is recency: oldest first.
  final _entries = <String, V>{}; // Map literals keep insertion order.
  Set<String> _visible = const {};

  int get length => _entries.length;
  Iterable<String> get names => _entries.keys;
  bool contains(String name) => _entries.containsKey(name);
  bool isVisible(String name) => _visible.contains(name);

  /// Returns the cached value and marks it most recently used.
  V? get(String name) {
    final value = _entries.remove(name);
    if (value != null) _entries[name] = value;
    return value;
  }

  /// Adds or replaces a tile. Returns the names evicted to make room.
  List<String> put(String name, V value) {
    final old = _entries.remove(name);
    if (old != null && !identical(old, value)) onEvict?.call(name, old);
    _entries[name] = value;
    // The tile just added is about to be drawn; keep it this round.
    return _trim(keep: name);
  }

  /// Sets the tiles currently in view, marks the cached ones most recently
  /// used, and returns the names evicted.
  List<String> setVisible(Iterable<String> names) {
    _visible = names.toSet();
    for (final name in _visible) {
      get(name);
    }
    return _trim();
  }

  List<String> _trim({String? keep}) {
    final evicted = <String>[];
    while (_entries.length > capacity) {
      String? victim;
      for (final name in _entries.keys) {
        if (name != keep && !_visible.contains(name)) {
          victim = name;
          break;
        }
      }
      if (victim == null) break;
      final value = _entries.remove(victim) as V;
      onEvict?.call(victim, value);
      evicted.add(victim);
    }
    return evicted;
  }
}
