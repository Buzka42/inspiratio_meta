import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/core/fog_settings.dart';

void main() {
  test('defaults to on', () async {
    final s = FogSettings(InMemoryKeyValueStore());
    expect(s.enabled, isTrue);
    await s.load();
    expect(s.enabled, isTrue);
  });
  test('persists off and reloads', () async {
    final store = InMemoryKeyValueStore();
    await FogSettings(store).setEnabled(false);
    final s2 = FogSettings(store);
    await s2.load();
    expect(s2.enabled, isFalse);
  });
}
