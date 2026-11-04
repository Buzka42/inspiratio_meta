import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/analysis_flow.dart';
import 'package:illunis_client/app/council_flow.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/health/analysis_input.dart';
import 'package:illunis_client/health/checkin.dart';
import 'package:illunis_client/health/daily_signals.dart';

import 'w5_fakes.dart';

// Synthetic check-ins and signals only.
const notice = 'This is not medical advice. Talk to a clinician about any health concern.';

void main() {
  late FakeServerPort server;
  late InMemoryStateStore store;
  late Speaker sp;
  late DateTime now;
  late AnalysisInput input;
  late AnalysisFlow flow;

  setUp(() {
    server = FakeServerPort()
      ..analysisResult = const AnalysisResult(
          comment: 'Your synthetic mood held steady.',
          notice: notice,
          sources: [CouncilSource(id: 's1', title: 'NHS: mood')]);
    store = InMemoryStateStore();
    sp = Speaker();
    now = DateTime(2026, 10, 25, 7);
    input = const AnalysisInput(
      checkins: [CheckIn(day: '2026-10-24', mood: 4, energy: 3, sleep: 4)],
      signals: [DailySignals(day: '2026-10-24', steps: 5000)],
      tz: 'Europe/Warsaw',
    );
    flow = AnalysisFlow(
      server: server,
      collect: () async => input,
      store: store,
      speaker: CouncilSpeaker(speak: sp.speak, caption: sp.caption),
      clock: () => now,
      log: (_) {},
    );
  });

  test('"how have I been doing" sends the 21-day body and speaks comment, notice, sources', () async {
    expect(flow.claim('How have I been doing?'), isTrue);
    await flow.settled;
    expect(server.analysisCalls.single, input.toJson());
    expect(sp.spoken.single, '${AnalysisPrompt.intro} Your synthetic mood held steady. $notice');
    expect(sp.captions.single, 'Sources: NHS: mood');
    expect(await store.getString(StoreKeys.analysisLastRun), '2026-10-25');
  });

  test('weekly: runs when never run, then not again for 7 days', () async {
    expect(await flow.weekly(), isTrue);
    expect(server.analysisCalls, hasLength(1));
    now = now.add(const Duration(days: 6));
    await flow.weekly();
    expect(server.analysisCalls, hasLength(1));
    now = now.add(const Duration(days: 1));
    await flow.weekly();
    expect(server.analysisCalls, hasLength(2));
  });

  test('weekly stays silent without a comment; the request speaks why', () async {
    server.analysisResult = const AnalysisResult(commentCode: 'nothing_to_comment', notice: notice);
    await flow.weekly();
    expect(sp.spoken, isEmpty);
    await flow.run(requested: true);
    expect(sp.spoken.single, AnalysisPrompt.notEnough);
    server.analysisResult = const AnalysisResult(commentCode: 'comment_number', notice: notice);
    await flow.run(requested: true);
    expect(sp.spoken.last, AnalysisPrompt.noComment);
  });

  test('no data: nothing is sent; the request says there is not enough', () async {
    input = const AnalysisInput(checkins: [], signals: [], tz: 'UTC');
    await flow.weekly();
    await flow.run(requested: true);
    expect(server.analysisCalls, isEmpty);
    expect(sp.spoken, [AnalysisPrompt.notEnough]);
  });

  test('a failed call does not mark the week, so the next digest retries', () async {
    server.analysisError = const ServerException(502, 'upstream_error');
    await flow.weekly();
    expect(sp.spoken, isEmpty);
    expect(await store.getString(StoreKeys.analysisLastRun), isNull);
    expect(await flow.due(), isTrue);
  });

  test('crisis speaks the referral text only', () async {
    server.analysisResult = const AnalysisResult(crisis: true, text: 'Synthetic referral.');
    await flow.run(requested: true);
    expect(sp.spoken.single, 'Synthetic referral.');
    expect(sp.captions, isEmpty);
  });
}
