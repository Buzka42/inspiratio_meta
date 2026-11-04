import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/app/tts_port.dart';
import 'package:illunis_client/output/speech_output.dart';
import 'package:illunis_client/output/tts_engine.dart';

void main() {
  test('SpeechOutputTts speaks prompts through SpeechOutput and completes', () async {
    final silent = SilentTts();
    final tts = SpeechOutputTts(SpeechOutput(TtsPortEngine(silent), log: (_) {}));
    await tts.speak('Please say proactive, or wait.');
    expect(silent.spoken.join(' '), contains('proactive'));
  });
}
