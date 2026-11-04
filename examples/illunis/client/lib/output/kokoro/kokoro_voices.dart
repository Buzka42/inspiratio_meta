/// English Kokoro voices and their sherpa-onnx speaker ids (sid).
///
/// The sids index voices.bin of the `kokoro-multi-lang-v1_0` archive
/// (hexgrad/Kokoro-82M VOICES.md order). The older `kokoro-en-v0_19`
/// archive uses different sids and has no af_heart, so it is not supported.
/// Confirm against `OfflineTts.numSpeakers` when a new archive is used.
library;

enum KokoroAccent { american, british }

class KokoroVoice {
  const KokoroVoice(this.name, this.sid, this.accent);
  final String name;
  final int sid;
  final KokoroAccent accent;
}

const defaultKokoroVoice = 'af_heart';

/// English only (PLAN.md). Non-English v1.0 voices are left out on purpose.
const kokoroEnglishVoices = <KokoroVoice>[
  KokoroVoice('af_alloy', 0, KokoroAccent.american),
  KokoroVoice('af_aoede', 1, KokoroAccent.american),
  KokoroVoice('af_bella', 2, KokoroAccent.american),
  KokoroVoice('af_heart', 3, KokoroAccent.american),
  KokoroVoice('af_jessica', 4, KokoroAccent.american),
  KokoroVoice('af_kore', 5, KokoroAccent.american),
  KokoroVoice('af_nicole', 6, KokoroAccent.american),
  KokoroVoice('af_nova', 7, KokoroAccent.american),
  KokoroVoice('af_river', 8, KokoroAccent.american),
  KokoroVoice('af_sarah', 9, KokoroAccent.american),
  KokoroVoice('af_sky', 10, KokoroAccent.american),
  KokoroVoice('am_adam', 11, KokoroAccent.american),
  KokoroVoice('am_echo', 12, KokoroAccent.american),
  KokoroVoice('am_eric', 13, KokoroAccent.american),
  KokoroVoice('am_fenrir', 14, KokoroAccent.american),
  KokoroVoice('am_liam', 15, KokoroAccent.american),
  KokoroVoice('am_michael', 16, KokoroAccent.american),
  KokoroVoice('am_onyx', 17, KokoroAccent.american),
  KokoroVoice('am_puck', 18, KokoroAccent.american),
  KokoroVoice('am_santa', 19, KokoroAccent.american),
  KokoroVoice('bf_alice', 20, KokoroAccent.british),
  KokoroVoice('bf_emma', 21, KokoroAccent.british),
  KokoroVoice('bf_isabella', 22, KokoroAccent.british),
  KokoroVoice('bf_lily', 23, KokoroAccent.british),
  KokoroVoice('bm_daniel', 24, KokoroAccent.british),
  KokoroVoice('bm_fable', 25, KokoroAccent.british),
  KokoroVoice('bm_george', 26, KokoroAccent.british),
  KokoroVoice('bm_lewis', 27, KokoroAccent.british),
];

/// Returns the voice called [name]; throws [ArgumentError] for any other name.
KokoroVoice kokoroVoice(String name) => kokoroEnglishVoices.firstWhere(
  (v) => v.name == name,
  orElse: () => throw ArgumentError.value(name, 'voice', 'not an English Kokoro voice'),
);
