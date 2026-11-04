/// Pure voice-turn state machine. No I/O: [reduce] returns the next state and
/// the commands the caller must execute, in order.
library;

enum VoiceState { idle, listening, thinking, speaking }

sealed class VoiceEvent {
  const VoiceEvent();
}

class WakeWordHeard extends VoiceEvent {
  const WakeWordHeard();
}

class UserSpeechStarted extends VoiceEvent {
  const UserSpeechStarted();
}

class UserSpeechEnded extends VoiceEvent {
  const UserSpeechEnded(this.transcript);
  final String transcript;
}

class ReplyChunk extends VoiceEvent {
  const ReplyChunk(this.text);
  final String text;
}

class ReplyDone extends VoiceEvent {
  const ReplyDone();
}

/// A typed turn (text chat). Works from every state: from idle it starts a
/// turn directly (no wake word, no listening); while Illunis thinks or
/// speaks it interrupts like a barge-in, then submits.
class TextSubmitted extends VoiceEvent {
  const TextSubmitted(this.text);
  final String text;
}

/// The user spoke while Illunis was speaking (or thinking).
class BargeIn extends VoiceEvent {
  const BargeIn();
}

sealed class VoiceCommand {
  const VoiceCommand();
}

class StartListening extends VoiceCommand {
  const StartListening();
  @override
  bool operator ==(Object other) => other is StartListening;
  @override
  int get hashCode => (StartListening).hashCode;
  @override
  String toString() => 'startListening';
}

/// Cancels audio playback immediately (the barge-in "cancel playback").
class StopPlayback extends VoiceCommand {
  const StopPlayback();
  @override
  bool operator ==(Object other) => other is StopPlayback;
  @override
  int get hashCode => (StopPlayback).hashCode;
  @override
  String toString() => 'stopPlayback';
}

class CancelGeneration extends VoiceCommand {
  const CancelGeneration();
  @override
  bool operator ==(Object other) => other is CancelGeneration;
  @override
  int get hashCode => (CancelGeneration).hashCode;
  @override
  String toString() => 'cancelGeneration';
}

/// Sends the finished user transcript to the reply generator.
class SubmitTranscript extends VoiceCommand {
  const SubmitTranscript(this.transcript);
  final String transcript;
  @override
  bool operator ==(Object other) =>
      other is SubmitTranscript && other.transcript == transcript;
  @override
  int get hashCode => transcript.hashCode;
  @override
  String toString() => 'submitTranscript';
}

class Speak extends VoiceCommand {
  const Speak(this.text);
  final String text;
  @override
  bool operator ==(Object other) => other is Speak && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'speak';
}

typedef VoiceStep = (VoiceState, List<VoiceCommand>);

const _interrupt = <VoiceCommand>[
  StopPlayback(),
  CancelGeneration(),
  StartListening(),
];

/// Pure transition function. Events that do not apply in [state] leave it
/// unchanged and emit no commands.
VoiceStep reduce(VoiceState state, VoiceEvent event) {
  switch ((state, event)) {
    case (VoiceState.idle, WakeWordHeard()):
      return (VoiceState.listening, const [StartListening()]);

    case (VoiceState.listening, UserSpeechEnded(:final transcript)):
      final text = transcript.trim();
      if (text.isEmpty) return (VoiceState.idle, const []);
      return (VoiceState.thinking, [SubmitTranscript(text)]);

    case (VoiceState.thinking, ReplyChunk(:final text)):
    case (VoiceState.speaking, ReplyChunk(:final text)):
      if (text.trim().isEmpty) return (state, const []);
      return (VoiceState.speaking, [Speak(text)]);

    case (VoiceState.thinking, ReplyDone()):
    case (VoiceState.speaking, ReplyDone()):
      return (VoiceState.idle, const []);

    // Typed turns never open listening: the microphone may be off.
    case (_, TextSubmitted(:final text)):
      final t = text.trim();
      if (t.isEmpty) return (state, const []);
      return (VoiceState.thinking, [
        if (state == VoiceState.speaking) const StopPlayback(),
        if (state == VoiceState.speaking || state == VoiceState.thinking) const CancelGeneration(),
        SubmitTranscript(t),
      ]);

    // User speech while Illunis speaks is a barge-in.
    case (VoiceState.speaking, BargeIn()):
    case (VoiceState.speaking, UserSpeechStarted()):
      return (VoiceState.listening, _interrupt);

    case (VoiceState.thinking, BargeIn()):
    case (VoiceState.thinking, UserSpeechStarted()):
      return (
        VoiceState.listening,
        const [CancelGeneration(), StartListening()],
      );

    default:
      return (state, const []);
  }
}
