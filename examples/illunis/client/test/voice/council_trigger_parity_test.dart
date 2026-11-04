// C5 parity: the Dart rule gives the same answer as server/src/council-trigger.js
// for each shared case (docs/NEBIUS_BUILD_PLAN.md, contract C5).
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/voice/council_trigger.dart';

void main() {
  const cases = {
    'why do I keep waking up at 3am every night': CouncilTrigger.offer,
    'what should I eat before a long run': CouncilTrigger.offer,
    'is it normal to feel tired after lunch': CouncilTrigger.offer,
    'ask the council about my sleep': CouncilTrigger.explicit,
    'I slept badly': CouncilTrigger.none,
    'hello there': CouncilTrigger.none,
    'tell me a story about the sea please': CouncilTrigger.none,
  };

  test('shared C5 cases', () {
    for (final e in cases.entries) {
      expect(councilTrigger(e.key), e.value, reason: e.key);
    }
  });
}
