// Typed text to parsed entry to Save? Yes / No (build plan B6). Synthetic text.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/persistence.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/logs/log_capture.dart';
import 'package:illunis_client/logs/log_entry.dart';
import 'package:illunis_client/logs/log_store.dart';

import 'log_fixtures.dart';

const referral = 'Synthetic referral text.';

({LogCapture capture, FakeServerPort server, LogStore store, InMemoryStateStore raw, List<String> logs}) rig(
    {LogKind kind = LogKind.run, String effort = 'none'}) {
  final server = FakeServerPort();
  final raw = InMemoryStateStore();
  final store = LogStore(raw);
  final logs = <String>[];
  final capture = LogCapture(
      kind: kind, server: server, store: store, date: () => day, effort: effort, log: logs.add);
  return (capture: capture, server: server, store: store, raw: raw, logs: logs);
}

void main() {
  test('typed text is parsed, previewed, and saved only on yes', () async {
    final r = rig();
    r.server.logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(run.toJson()));
    await r.capture.submit('5 km in 26 min');
    final call = r.server.logParseCalls.single;
    expect((call.kind, call.text, call.date), ('run', '5 km in 26 min', day));
    expect(call.prefs, {'effort': 'none'});
    expect(r.capture.state, isA<CapturePreview>());
    expect(await r.store.forDay(LogKind.run, day), isEmpty);

    await r.capture.submit('yes');
    expect(r.capture.state, isA<CaptureMessage>());
    expect((r.capture.state as CaptureMessage).text, CaptureText.saved);
    final saved = await r.store.forDay(LogKind.run, day);
    expect(saved.single.toJson(), run.toJson());

    // Stored on the phone under its own key, and reloadable.
    final again = LogStore(r.raw);
    expect((await again.forDay(LogKind.run, day)).single.toJson(), run.toJson());
    expect(await r.raw.getString(StoreKeys.logs), isNotNull);
    // Logs carry codes only, never the text.
    expect(r.logs.join('\n'), isNot(contains('26 min')));
  });

  test('a tapped no (or typed no) discards the entry', () async {
    final r = rig();
    r.server.logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(run.toJson()));
    await r.capture.submit('5 km in 26 min');
    await r.capture.answer(false);
    expect((r.capture.state as CaptureMessage).text, CaptureText.discarded);
    expect(await r.store.forDay(LogKind.run, day), isEmpty);

    await r.capture.submit('5 km in 26 min');
    await r.capture.submit('no');
    expect(await r.store.forDay(LogKind.run, day), isEmpty);
    // A yes with nothing pending saves nothing and is parsed as a line.
    await r.capture.answer(true);
    expect(await r.store.forDay(LogKind.run, day), isEmpty);
  });

  test('a new line with a preview open drops the preview unsaved', () async {
    final r = rig();
    r.server.logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(run.toJson()));
    await r.capture.submit('5 km in 26 min');
    await r.capture.submit('6 km in 31 min');
    expect(r.server.logParseCalls.length, 2);
    expect(r.capture.state, isA<CapturePreview>());
    expect(await r.store.forDay(LogKind.run, day), isEmpty);
  });

  test('crisis text shows the referral and saves nothing', () async {
    final r = rig();
    r.server.logParseResult = const LogParseResult.crisis(referral);
    await r.capture.submit('synthetic crisis line');
    expect(r.capture.state, isA<CaptureCrisis>());
    expect((r.capture.state as CaptureCrisis).referral, referral);
    await r.capture.submit('yes');
    expect(await r.store.forDay(LogKind.run, day), isEmpty);
  });

  test('a rejected code shows a short message, never the raw code', () async {
    for (final code in ['number_not_in_text', 'out_of_range', 'empty_entry', 'bad_json', 'bad_field', 'not_object']) {
      final r = rig();
      r.server.logParseResult = LogParseResult.rejected(code);
      await r.capture.submit('ran a bit');
      final s = r.capture.state;
      expect(s, isA<CaptureMessage>(), reason: code);
      final text = (s as CaptureMessage).text;
      expect(text, isNot(contains(code)));
      expect(text, isNot(contains('_')));
      expect(text.length, lessThan(120));
    }
  });

  test('a server failure or a wrong kind shows a short message', () async {
    final r = rig();
    r.server.logParseError = const ServerException(503, 'not_configured');
    await r.capture.submit('5 km in 26 min');
    expect((r.capture.state as CaptureMessage).text, CaptureText.unavailable);

    r.server.logParseError = null;
    r.server.logParseResult = LogParseResult.parsed(Map<String, dynamic>.from(rowing.toJson()));
    await r.capture.submit('5 km in 26 min');
    expect(r.capture.state, isA<CaptureMessage>());
  });

  test('effort is sent only when chosen: the pref or the scale written in the line', () async {
    final r = rig(kind: LogKind.strength);
    await r.capture.submit('squat 3x5 at 100 kg');
    await r.capture.submit('squat 3x5 at 100 kg RIR 2');
    await r.capture.submit('squat 3x5 at 100 kg @ RPE 8');
    expect(r.server.logParseCalls.map((c) => c.prefs['effort']), ['none', 'rir', 'rpe']);
    final withPref = rig(kind: LogKind.strength, effort: 'rpe');
    await withPref.capture.submit('squat 3x5 at 100 kg');
    expect(withPref.server.logParseCalls.single.prefs['effort'], 'rpe');
    final runRig = rig(effort: 'rpe');
    await runRig.capture.submit('5 km RPE 6');
    expect(runRig.server.logParseCalls.single.prefs['effort'], 'none');
  });

  test('input is ignored while a parse is in flight', () async {
    final r = rig();
    final gate = Completer<void>();
    r.server.logParseGate = gate;
    final first = r.capture.submit('5 km in 26 min');
    expect(r.capture.state, isA<CaptureReading>());
    await r.capture.submit('again');
    expect(r.server.logParseCalls.length, 1);
    gate.complete();
    await first;
  });

  group('HttpServerPort.parseLog', () {
    late HttpServer srv;
    late HttpServerPort port;
    var status = 200;
    Object reply = {};
    final seen = <Map<String, dynamic>>[];

    setUp(() async {
      seen.clear();
      srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((req) async {
        expect('${req.method} ${req.uri.path}', 'POST /log/parse');
        seen.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>);
        req.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(reply));
        await req.response.close();
      });
      port = HttpServerPort('http://127.0.0.1:${srv.port}', deviceToken: 'synthetic-device.c3ludGhldGlj');
    });

    tearDown(() async {
      port.close();
      await srv.close(force: true);
    });

    test('ok, crisis and a 422 code', () async {
      status = 200;
      reply = {'ok': true, ...run.toJson()};
      final ok = await port.parseLog('run', '5 km', prefs: {'effort': 'none'}, date: day);
      expect(seen.single, {'kind': 'run', 'text': '5 km', 'prefs': {'effort': 'none'}, 'date': day});
      expect(LogEntry.fromJson(ok.envelope)?.kind, LogKind.run);

      reply = {'ok': false, 'code': 'crisis', 'crisis': true, 'text': referral};
      final c = await port.parseLog('run', 'x');
      expect((c.crisis, c.referral), (true, referral));
      expect(seen.last.containsKey('date'), isFalse);

      status = 422;
      reply = {'ok': false, 'code': 'number_not_in_text'};
      final bad = await port.parseLog('run', 'x');
      expect((bad.ok, bad.code), (false, 'number_not_in_text'));
    });

    test('other failures throw ServerException', () async {
      status = 503;
      reply = {'error': 'not_configured'};
      await expectLater(port.parseLog('run', 'x'), throwsA(isA<ServerException>()));
    });
  });
}
