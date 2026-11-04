import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/health/health_port.dart';
import 'package:illunis_client/health/health_setup.dart';

// Health Connect permission asked by voice first. Synthetic only.

void main() {
  late FakeHealthPort port;
  late InMemoryStateStore store;
  late List<String> spoken;
  late int listens;

  HealthSetup build({bool ready = true}) => HealthSetup(
        port: port,
        store: store,
        speak: (t) async => spoken.add(t),
        listen: () => listens++,
        ready: () => ready,
        log: (_) {},
      );

  setUp(() {
    port = FakeHealthPort();
    store = InMemoryStateStore();
    spoken = [];
    listens = 0;
  });

  test('asks by voice; "yes" opens the system sheet', () async {
    final h = build();
    await h.offer();
    expect(spoken.single, HealthPrompt.offer);
    expect(listens, 1);
    expect(port.permissionRequests, 0); // Nothing before the spoken yes.
    expect(h.claim('yes please'), isTrue);
    await h.settled;
    expect(port.permissionRequests, 1);
    expect(spoken.sublist(1), [HealthPrompt.sheet, HealthPrompt.granted]);
    expect(await store.getBool(StoreKeys.healthAsked), isTrue);
  });

  test('"no" never opens the sheet and is not asked again', () async {
    final h = build();
    await h.offer();
    h.claim('no');
    await h.settled;
    expect(port.permissionRequests, 0);
    expect(spoken.last, HealthPrompt.declined);
    final again = build();
    await again.load();
    await again.offer();
    expect(spoken.where((t) => t == HealthPrompt.offer), hasLength(1));
  });

  test('an unclear answer re-asks; a denied sheet is spoken', () async {
    port.grantOnRequest = HealthPermission.denied;
    final h = build();
    await h.offer();
    h.claim('maybe later perhaps');
    await h.settled;
    expect(spoken.last, HealthPrompt.reask);
    h.claim('yes');
    await h.settled;
    expect(spoken.last, HealthPrompt.denied);
  });

  test('not offered when Health Connect is missing, already granted, or not ready', () async {
    port.available = HealthAvailability.notInstalled;
    await build().offer();
    port.available = HealthAvailability.available;
    port.granted = true;
    await build().offer();
    port.granted = false;
    await build(ready: false).offer();
    expect(spoken, isEmpty);
  });

  test('"connect Health Connect" asks again later; missing app is spoken', () async {
    expect(isHealthIntent('Connect Health Connect.'), isTrue);
    expect(isHealthIntent('read my sleep data'), isTrue);
    expect(isHealthIntent('how did I sleep'), isFalse);
    final h = build();
    expect(h.claim('connect health connect'), isTrue);
    await h.settled;
    expect(spoken.single, HealthPrompt.offer);
    h.claim('yes');
    await h.settled;
    expect(port.permissionRequests, 1);

    spoken.clear();
    port.available = HealthAvailability.updateRequired;
    final later = build()..claim('use my health data');
    await later.settled;
    expect(spoken, [HealthPrompt.update]);
  });
}
