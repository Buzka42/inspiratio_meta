import 'package:flutter_test/flutter_test.dart';

import 'package:illunis_client/voice/voice_session.dart';

void main() {
  test('wake word starts listening', () {
    final (s, c) = reduce(VoiceState.idle, const WakeWordHeard());
    expect(s, VoiceState.listening);
    expect(c, [const StartListening()]);
  });

  test('speech end submits transcript and thinks', () {
    final (s, c) = reduce(VoiceState.listening, const UserSpeechEnded(' plan my day '));
    expect(s, VoiceState.thinking);
    expect(c, [const SubmitTranscript('plan my day')]);
  });

  test('empty transcript returns to idle', () {
    final (s, c) = reduce(VoiceState.listening, const UserSpeechEnded('  '));
    expect(s, VoiceState.idle);
    expect(c, isEmpty);
  });

  test('reply chunks speak, reply done goes idle', () {
    var (s, c) = reduce(VoiceState.thinking, const ReplyChunk('Hello.'));
    expect(s, VoiceState.speaking);
    expect(c, [const Speak('Hello.')]);
    (s, c) = reduce(s, const ReplyChunk('More.'));
    expect(s, VoiceState.speaking);
    expect(c, [const Speak('More.')]);
    (s, c) = reduce(s, const ReplyDone());
    expect(s, VoiceState.idle);
    expect(c, isEmpty);
  });

  test('barge-in while speaking cancels playback and generation, listens', () {
    final (s, c) = reduce(VoiceState.speaking, const BargeIn());
    expect(s, VoiceState.listening);
    expect(c, [const StopPlayback(), const CancelGeneration(), const StartListening()]);
  });

  test('user speech while speaking is treated as barge-in', () {
    final (s, c) = reduce(VoiceState.speaking, const UserSpeechStarted());
    expect(s, VoiceState.listening);
    expect(c.first, const StopPlayback());
  });

  test('barge-in while thinking cancels generation only', () {
    final (s, c) = reduce(VoiceState.thinking, const BargeIn());
    expect(s, VoiceState.listening);
    expect(c, [const CancelGeneration(), const StartListening()]);
  });

  test('irrelevant events are ignored', () {
    for (final (state, event) in [
      (VoiceState.idle, const ReplyChunk('x')),
      (VoiceState.idle, const BargeIn()),
      (VoiceState.listening, const WakeWordHeard()),
      (VoiceState.speaking, const WakeWordHeard()),
      (VoiceState.idle, const UserSpeechEnded('hi')),
    ]) {
      final (s, c) = reduce(state, event);
      expect(s, state);
      expect(c, isEmpty);
    }
  });

  test('full turn with barge-in', () {
    final events = <VoiceEvent>[
      const WakeWordHeard(),
      const UserSpeechStarted(),
      const UserSpeechEnded('weather'),
      const ReplyChunk('It is'),
      const BargeIn(),
      const UserSpeechEnded('stop'),
    ];
    var state = VoiceState.idle;
    final all = <VoiceCommand>[];
    for (final e in events) {
      final (s, c) = reduce(state, e);
      state = s;
      all.addAll(c);
    }
    expect(state, VoiceState.thinking);
    expect(all, [
      const StartListening(),
      const SubmitTranscript('weather'),
      const Speak('It is'),
      const StopPlayback(),
      const CancelGeneration(),
      const StartListening(),
      const SubmitTranscript('stop'),
    ]);
  });

  group('TextSubmitted (typed turns)', () {
    test('from idle it thinks and submits, without listening', () {
      final (s, c) = reduce(VoiceState.idle, const TextSubmitted(' plan my day '));
      expect(s, VoiceState.thinking);
      expect(c, [const SubmitTranscript('plan my day')]);
    });

    test('a reply chunk after a typed turn from idle is spoken', () {
      var (s, _) = reduce(VoiceState.idle, const TextSubmitted('hello'));
      final List<VoiceCommand> c;
      (s, c) = reduce(s, const ReplyChunk('Hi.'));
      expect(s, VoiceState.speaking);
      expect(c, [const Speak('Hi.')]);
      expect(reduce(s, const ReplyDone()).$1, VoiceState.idle);
    });

    test('while speaking it interrupts, then submits', () {
      final (s, c) = reduce(VoiceState.speaking, const TextSubmitted('stop that'));
      expect(s, VoiceState.thinking);
      expect(c, [const StopPlayback(), const CancelGeneration(), const SubmitTranscript('stop that')]);
    });

    test('while thinking it cancels the generation, then submits', () {
      final (s, c) = reduce(VoiceState.thinking, const TextSubmitted('never mind'));
      expect(s, VoiceState.thinking);
      expect(c, [const CancelGeneration(), const SubmitTranscript('never mind')]);
    });

    test('while listening it submits', () {
      final (s, c) = reduce(VoiceState.listening, const TextSubmitted('typed'));
      expect(s, VoiceState.thinking);
      expect(c, [const SubmitTranscript('typed')]);
    });

    test('empty text changes nothing', () {
      for (final st in VoiceState.values) {
        final (s, c) = reduce(st, const TextSubmitted('   '));
        expect(s, st);
        expect(c, isEmpty);
      }
    });
  });
}
