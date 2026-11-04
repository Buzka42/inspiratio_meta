import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/council_flow.dart';
import 'package:illunis_client/app/morning_flow.dart';
import 'package:illunis_client/app/server_port.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/output/speech_fakes.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/voice/alarm_digest.dart';
import 'package:illunis_client/voice/morning_interview.dart';

// The morning digest with the council the server runs inside /digest, the
// folded-in extras (inbox, weekly analysis) and the check-in. Synthetic only.
const today = LocalDate(2026, 10, 25);
const disclaimer = notMedicalAdviceLine;

Future<MorningFlow> interviewed(FakeServerPort server, SpeechOutput speech) async {
  final f = MorningFlow(tts: SilentTts(), server: server, alarm: const LocalTime(7, 0), speech: speech);
  await f.answer(const Acknowledge());
  await f.answer(const ProactiveAnswer(ProactiveMode.wait));
  await f.answer(const KeywordAnswer('Altair'));
  await f.answer(const PersonalityAnswer('coach'));
  await f.answer(const ConfirmAnswer(true));
  return f;
}

void main() {
  late FakeTtsEngine engine;
  late FakeServerPort server;
  late MorningFlow flow;
  late List<String> captions, order;

  setUp(() async {
    engine = FakeTtsEngine();
    server = FakeServerPort();
    captions = [];
    order = [];
    flow = await interviewed(server, SpeechOutput(engine, log: (_) {}));
    flow
      ..councilContext = (() => const CouncilContext(shortTermSummary: 'Earlier: synthetic'))
      ..councilSpeaker = CouncilSpeaker(
          speak: (t) async {
            order.add('council');
            var ok = true;
            await for (final e in flow.speech.speak(t)) {
              ok = e is! PlaybackCancelled && e is! PlaybackFailed;
            }
            return ok;
          },
          caption: captions.add)
      ..digestExtras = () async {
        order.add('extras');
        return true;
      }
      ..afterDigest = () async => order.add('checkin');
  });

  test('the digest sends the short-term context and speaks the council answer after it', () async {
    server.digestResult = const DigestResult(
      text: 'Synthetic digest.',
      council: CouncilResult(
          synthesis: 'Synthetic council view.', sources: [CouncilSource(id: 'n1', title: 'NHS: sleep')]),
    );
    await flow.tick(now: const LocalTime(7, 0), today: today);
    expect(server.digestContexts.single.context?.shortTermSummary, 'Earlier: synthetic');
    expect(server.digestContexts.single.council, isTrue);
    expect(engine.played, ['Synthetic digest.', 'Synthetic council view.']);
    expect(captions, ['Sources: NHS: sleep']);
    expect(order, ['council', 'extras', 'checkin']);
  });

  test('a medical council answer carries the line; the digest disclaimer is not repeated', () async {
    server.digestResult = const DigestResult(
      text: 'Synthetic digest.',
      health: true,
      disclaimer: disclaimer,
      council: CouncilResult(synthesis: 'Synthetic medical view.', medical: true),
    );
    await flow.tick(now: const LocalTime(7, 0), today: today);
    expect(engine.played, ['Synthetic digest.', 'Synthetic medical view.', ...disclaimer.split(RegExp(r'(?<=\.) '))]);
    expect(engine.played.where((s) => s == 'This is not medical advice.'), hasLength(1));
  });

  test('no council (not configured, quota): digest, disclaimer, extras, check-in as before', () async {
    server.digestResult =
        const DigestResult(text: 'Synthetic digest.', disclaimer: 'Synthetic disclaimer.', councilCode: 'council_quota');
    await flow.tick(now: const LocalTime(7, 0), today: today);
    expect(engine.played, ['Synthetic digest.', 'Synthetic disclaimer.']);
    expect(order, ['extras', 'checkin']);
  });

  test('extras the user interrupts skip the check-in', () async {
    server.digestResult = const DigestResult(text: 'Synthetic digest.');
    flow.digestExtras = () async {
      order.add('extras');
      return false;
    };
    await flow.tick(now: const LocalTime(7, 0), today: today);
    expect(order, ['extras']);
  });
}
