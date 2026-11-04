// The council trace (T18): the server's trace parsed, turned into one line
// per expert and a web search line, handed on after a whole answer played,
// and kept on the thread. Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/chat_thread.dart';
import 'package:illunis_client/app/council_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';

Map<String, Object> consult(String expert, String field,
        {List<(String, String)> sources = const [], String web = 'not_needed', String? via, bool answered = true}) =>
    {
      'expert': expert,
      'field': field,
      'question': 'synthetic question for $expert',
      'sources': [for (final (t, k) in sources) {'title': t, 'kind': k}],
      'web_search': web,
      'web_via': ?via,
      'answered': answered,
    };

CouncilTrace trace(List<Object> entries) => CouncilTrace.fromJson(entries);

void main() {
  test('CouncilResult parses the trace: consults in order, then the notes', () {
    final r = CouncilResult.fromJson({
      'synthesis': 'Synthetic synthesis.',
      'trace': [
        consult('sleep_lifestyle', 'sleep and lifestyle', sources: [('Synthetic A', 'bank'), ('Synthetic W', 'web')], web: 'used', via: 'tavily'),
        {'note': 'time_limit'},
        'junk',
        {'expert': ''},
      ],
    });
    expect(r.trace.consults, hasLength(1));
    final c = r.trace.consults.single;
    expect((c.expert, c.field, c.webSearch, c.webVia, c.answered), ('sleep_lifestyle', 'sleep and lifestyle', WebSearch.used, 'tavily', true));
    expect([for (final s in c.sources) (s.title, s.web)], [('Synthetic A', false), ('Synthetic W', true)]);
    expect(r.trace.notes, ['time_limit']);
    expect(CouncilResult.fromJson({'synthesis': 'x'}).trace.isEmpty, isTrue, reason: 'no trace from the server');
  });

  test('lines: a bank-only expert, web search not needed', () {
    final t = trace([
      consult('sleep_lifestyle', 'sleep and lifestyle', sources: [('A', 'bank'), ('B', 'bank'), ('C', 'bank')]),
    ]);
    expect(councilTraceLines(t), ['Sleep and lifestyle: 3 sources, web search not needed', 'Web search: not needed']);
  });

  test('lines: a Tavily-backed expert says used, and the web line names Tavily', () {
    final t = trace([
      consult('diet', 'diet and nutrition', sources: [('A', 'bank'), ('W', 'web')], web: 'used', via: 'tavily'),
      consult('training', 'training and movement', sources: [('T1', 'bank'), ('T2', 'bank')]),
    ]);
    expect(councilTraceLines(t), [
      'Diet and nutrition: 1 bank and 1 web source, web search used',
      'Training and movement: 2 sources, web search not needed',
      'Web search (Tavily): ran for Diet and nutrition',
    ]);
  });

  test('lines: web search unavailable, an expert that did not answer, a repeat consult, the limit notes', () {
    final t = trace([
      consult('diet', 'diet and nutrition', web: 'unavailable'),
      consult('training', 'training and movement', sources: [('T1', 'bank')], answered: false),
      consult('sleep_lifestyle', 'sleep and lifestyle', sources: [('S1', 'bank'), ('S2', 'bank')]),
      consult('sleep_lifestyle', 'sleep and lifestyle', sources: [('S2', 'bank'), ('S3', 'bank')]),
      {'note': 'consult_limit'},
      {'note': 'time_limit'},
    ]);
    expect(councilTraceLines(t), [
      'Diet and nutrition: no sources, web search unavailable',
      'Training and movement: did not answer',
      'Sleep and lifestyle: 3 sources, web search not needed',
      'Web search: unavailable',
      'The council closed at its consult limit.',
      'The council closed at its time limit.',
    ]);
    expect(councilTraceLines(const CouncilTrace()), isEmpty);
  });

  group('CouncilSpeaker', () {
    final r = CouncilResult(
      synthesis: 'Synthetic synthesis.',
      trace: trace([consult('diet', 'diet and nutrition', sources: [('A', 'bank'), ('B', 'bank')])]),
    );

    test('hands the trace on after the whole answer played', () async {
      final got = <List<String>>[];
      final s = CouncilSpeaker(speak: (_) async => true, trace: got.add);
      expect(await s.say(r), isTrue);
      expect(got, [
        ['Diet and nutrition: 2 sources, web search not needed', 'Web search: not needed'],
      ]);
    });

    test('no trace when the answer was cut, on a crisis, or with no trace', () async {
      final got = <List<String>>[];
      expect(await CouncilSpeaker(speak: (_) async => false, trace: got.add).say(r), isFalse);
      final crisis = CouncilResult(synthesis: 'Referral.', crisis: true, trace: r.trace);
      await CouncilSpeaker(speak: (_) async => true, trace: got.add).say(crisis);
      await CouncilSpeaker(speak: (_) async => true, trace: got.add).say(const CouncilResult(synthesis: 'x'));
      expect(got, isEmpty);
    });
  });

  test('the thread keeps the trace on the answer bubble, across a restart', () async {
    final store = InMemoryStateStore();
    final t = ChatThread(store: store)
      ..addUser('Synthetic question?')
      ..addAssistant('Synthetic answer.')
      ..attachSources('Sources: A')
      ..attachTrace(['Diet: 2 sources, web search not needed', 'Web search: not needed']);
    expect(t.entries.last.trace, hasLength(2));
    expect(t.traceOpen, isTrue, reason: 'open by default');
    t.toggleTrace();
    expect(t.traceOpen, isFalse);
    // A new sentence does not merge into a bubble that carries a trace.
    t.addAssistant('Next.');
    expect(t.entries, hasLength(3));
    await t.saved;
    final again = ChatThread(store: store);
    await again.load();
    expect(again.entries[1].trace, ['Diet: 2 sources, web search not needed', 'Web search: not needed']);
    expect(again.entries[1].sources, 'Sources: A');
  });
}
