// The "Answered by" line in the council trace (W8): which brain answered,
// named honestly, and the spoken text left unchanged. Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/council_flow.dart';
import 'package:illunis_client/app/server_port.dart';

void main() {
  test('maps each provider id to its name', () {
    expect(answeredByLine(['meta']), 'Answered by: Muse');
    expect(answeredByLine(['nebius']), 'Answered by: Nebius');
    expect(answeredByLine(['openrouter_poc']), 'Answered by: a test model');
    expect(answeredByLine(['opencode_poc']), 'Answered by: a test model');
    expect(answeredByLine(['mystery_llm']), 'Answered by: another model');
  });

  test('a later provider reads as the fallback, a repeated name once', () {
    expect(answeredByLine(['meta', 'nebius']), 'Answered by: Muse, then Nebius (fallback)');
    expect(answeredByLine(['openrouter_poc', 'opencode_poc']), 'Answered by: a test model');
  });

  test('an empty list gives no line', () {
    expect(answeredByLine(const []), isNull);
    expect(councilTraceLines(const CouncilTrace()), isEmpty);
  });

  test('the line follows the web search line in the trace', () {
    final t = CouncilTrace(
        consults: [CouncilConsult(expert: 'sleep', field: 'Sleep', sources: const [CouncilTraceSource('A', web: false)])],
        notes: const ['time_limit']);
    expect(councilTraceLines(t, providers: ['meta', 'nebius']), [
      'Sleep: 1 source, web search not needed',
      'Web search: not needed',
      'Answered by: Muse, then Nebius (fallback)',
      'The council closed at its time limit.',
    ]);
  });

  test('the speaker shows the line in the trace and speaks the synthesis unchanged', () async {
    final spoken = <String>[], traces = <List<String>>[];
    final s = CouncilSpeaker(speak: (t) async {
      spoken.add(t);
      return true;
    }, trace: traces.add);
    await s.say(const CouncilResult(synthesis: 'Sleep earlier.', providers: ['meta']));
    expect(spoken, ['Sleep earlier.']);
    expect(traces, [
      ['Answered by: Muse']
    ]);
  });
}
