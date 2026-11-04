/// Voice switch (PLAN.md decision 2026-10-28). Off by default: text chat is
/// the main interface, the microphone is never started, and replies are
/// written into the chat thread instead of spoken. Build with
/// --dart-define=ILLUNIS_VOICE=true to bring the voice stack back. Voice code
/// stays in place either way; Kokoro is kept for breathwork.
library;

const voiceEnabled = bool.fromEnvironment('ILLUNIS_VOICE');
