import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'alarm/alarm_scheduler.dart';
import 'alarm/alarm_settings.dart';
import 'alarm/notification_port.dart';
import 'app/alarm_coordinator.dart';
import 'app/analysis_flow.dart';
import 'app/app_controller.dart';
import 'app/approval_flow.dart';
import 'app/assistant_bridge.dart';
import 'app/assistant_inbox.dart';
import 'app/chat_thread.dart';
import 'app/council_flow.dart';
import 'app/digest_ticker.dart';
import 'app/illunis_root.dart';
import 'app/moon_focus.dart';
import 'app/moon_setup.dart';
import 'app/morning_flow.dart';
import 'app/persistence.dart';
import 'app/server_port.dart';
import 'app/spec_chat.dart';
import 'app/speech_wiring.dart';
import 'app/tts_port.dart';
import 'app/view_intents.dart';
import 'app/view_offer.dart';
import 'app/voice_setup.dart';
import 'app/water_port.dart';
import 'app/memory_writer.dart';
import 'core/fog_settings.dart';
import 'core/voice_flags.dart';
import 'health/analysis_input.dart';
import 'logs/chat_food_log.dart';
import 'logs/log_capture.dart';
import 'logs/log_entry.dart';
import 'logs/log_store.dart';
import 'logs/views/log_views.dart';
import 'health/checkin.dart';
import 'health/daily_signals.dart' show dayKey;
import 'health/health_port.dart';
import 'health/health_setup.dart';
import 'health/imported_signals.dart';
import 'input/input_pipeline.dart';
import 'input/gated_speech_to_text.dart';
import 'input/input_stubs.dart';
import 'input/live_mic.dart';
import 'input/mic_channel.dart';
import 'input/stt/sherpa_whisper_stt.dart';
import 'input/stt/whisper_model.dart';
import 'memory/assistant_memory_backend.dart';
import 'memory/local_memory_backend.dart';
import 'memory/memory_mode.dart';
import 'memory/owner_import_loader.dart';
import 'memory/short_term_memory.dart';
import 'output/speech_output.dart';
import 'output/thread_engine.dart';
import 'output/tts_engine.dart';
import 'voice/voice_session.dart';
import 'voice/wake_phrase_setup.dart';
import 'voice/wake_wiring.dart';

/// Worker base URL, set with --dart-define=ILLUNIS_SERVER_URL=...
/// Empty (the default) uses the offline fake server.
const serverUrl = String.fromEnvironment('ILLUNIS_SERVER_URL');

/// Device token for the Worker, set with
/// --dart-define=ILLUNIS_DEVICE_TOKEN=... Never hard-code or print it.
/// Empty (the default) keeps the offline fake even when a URL is set.
const _deviceToken = String.fromEnvironment('ILLUNIS_DEVICE_TOKEN');


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Full screen: the sky runs under the system bars; the bars come back only on a swipe.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // shared_preferences behind a guard: a failing store logs and the app
  // runs on defaults.
  final store = persistentStore();
  final server = serverPortFor(serverUrl, deviceToken: _deviceToken);
  final silent = SilentTts(); // Captions-only fallback when Kokoro is off.
  // Speech is always on (PLAN.md, decisions 2026-10-24): Kokoro on
  // sherpa-onnx through the native player, model in the app support dir
  // (app/speech_wiring.dart). Dev and debug builds pass
  // --dart-define=ILLUNIS_KOKORO_GPL_CHECKED=true; without it (release until
  // the espeak-ng check) or without the pushed model, the silent adapter
  // stays and replies reach the screen as captions only. Logs the code only.
  final supportDir = await _supportDir();
  final voice = await wireSpeech(supportDir, fallback: TtsPortEngine(silent));
  // Text chat (core/voice_flags.dart, default off): with voice off the main
  // output writes each sentence into the chat thread instead of speaking.
  // Kokoro (voice.engine) stays wired for breathwork.
  final thread = ChatThread(store: store);
  await thread.load();
  final speech = SpeechOutput(voiceEnabled ? voice.engine : ThreadEngine(thread.addAssistant));
  // Prompts (setup, check-ins, digest, asides) speak through the same output
  // as replies; they were silent before (device test 2026-10-25).
  final tts = SpeechOutputTts(speech);
  // Release the player and the backend when the engine detaches (app exit).
  AppLifecycleListener(onDetach: () => unawaited(voice.dispose()));
  // The moon map (NASA SVS, bundled) and its zoom. Voice commands for the
  // main view ("zoom in on the moon", "classic mode") are matched before a
  // transcript becomes a server turn. Reflection is the default mode.
  final focus = MoonFocus(moon: await loadBundledMoon());
  // Memory (docs/DESIGN.md): short-term context on
  // the phone (this conversation plus the last 5 session summaries) and
  // long-term notes in the backend chosen by voice, the phone by default.
  // Both go with each /turn and /reply. A session is summarised through
  // POST /session/summary when the app goes to the background.
  final shortTerm = ShortTermMemory(store: store, summarise: server.sessionSummary);
  await shortTerm.load();
  final phoneMemory = LocalMemoryBackend(store);
  final importedSignals = ImportedSignalsStore(store);
  // One-time owner import pushed by tool/push_owner_import.sh: idempotent by
  // note id, the bundle file is deleted once stored. Logs counts only.
  await loadOwnerImport(supportDir: supportDir, memory: phoneMemory, signals: importedSignals);
  final longTerm = SelectedMemoryBackend(phone: phoneMemory, assistant: AssistantMemoryBackend(server));
  final controller = AppController(
      fog: FogSettings(store),
      server: server,
      tts: tts,
      speech: speech,
      modes: ViewModeController(focus: focus),
      memory: MemoryWriter(longTerm, log: debugPrint),
      shortTerm: shortTerm);
  AppLifecycleListener(onPause: () => unawaited(shortTerm.endSession()));
  controller.turnRequests.listen(controller.routeTurn);
  await controller.load();

  // The digest shares the controller's SpeechOutput, so a wake word or
  // barge-in during the digest cancels it (AppController.dispatch).
  final flow = MorningFlow(tts: tts, server: server, store: store, speech: speech);
  await flow.load();

  // Alarm settings are set by voice (VoiceSetup below), never a screen.
  // The scheduler and the notification port are TODO stubs: the native side is not built, so no
  // alarm or notification reaches the device yet.
  final alarm = AlarmCoordinator(
    settingsStore: AlarmSettingsStore(store),
    scheduler: MethodChannelAlarmScheduler(),
    notifications: MethodChannelNotificationPort(),
    flow: flow,
    controller: controller,
  );
  await alarm.start();
  final ticker = DigestTicker(flow: flow)..start();

  // The first frame comes before the microphone: the RECORD_AUDIO prompt
  // must not hold the screen, and startCapture needs the visible activity.
  // Views open only through ViewHost.open, after a yes (ViewOffer below).
  final views = ViewHost();
  // One store: the chat's meal lines and the log views read and write it.
  final logStore = LogStore(store);
  runApp(IllunisRoot(
      controller: controller,
      ticker: ticker,
      water: waterPort(),
      focus: focus,
      chat: voiceEnabled ? null : thread,
      views: views,
      logs: LogViews(
          store: logStore,
          server: server,
          signals: () async => (await ChannelHealthPort().readDaily(days: 7)).days)));

  // Wake phrase (2 to 4 words): asked by voice after the
  // interview and stored under wake_phrase. Changing it restarts spotting.
  late final InputPipeline input;
  void listenAfterPrompt() {
    if (input.status == InputStatus.running) controller.dispatch(const WakeWordHeard());
  }

  final wakePhrase = WakePhraseSetup(
    store: WakePhraseStore(read: store.getString, write: store.setString),
    speak: flow.tts.speak,
    listen: listenAfterPrompt,
    onPhraseChanged: () => input.refreshKeyword(),
    ready: () => flow.interviewDone,
  );
  await wakePhrase.load();

  // Wake port, chosen again at each listen: the sherpa-onnx KWS engine for a
  // valid stored phrase when its model is in {support dir}/models/kws/...
  // (not bundled; pushed by the owner), else the old single-word port. A
  // failed engine start also falls back (WakeEngineAdapter).
  final legacyWake = StubWakeWordPort();
  final wakeWord = PhraseSwitchingWakePort(
    phrase: () => wakePhrase.phrase?.text,
    choose: (p) => chooseWakeWordPort(
      legacy: legacyWake,
      enginePhrase: p,
      modelDir: kwsModelDir(supportDir),
      buildEngine: (phrase, model) => sherpaWakePort(phrase, model, legacyWake),
    ),
  );

  // Microphone (input/live_mic.dart): RECORD_AUDIO asked once on
  // `illunis/mic`; granted gives the live capture on `illunis/mic/pcm`
  // (VOICE_RECOGNITION, AGC and NS off), feeding the wake port above. Denied
  // or no channel keeps the stubs (log input: mic_fallback code=...), and a
  // capture that cannot start logs mic_unavailable; the app runs on either.
  // Each listening session passes the whispered-input gate (guard, then one
  // capped gain) before the recogniser: sherpa-onnx Whisper tiny.en on a
  // worker isolate when its model is in {support dir}/models/stt/... (not
  // bundled; input/stt/whisper_model.dart lists the files), else the stub
  // (log input: stt_engine_off code=stt_model_missing).
  // Voice off: no RECORD_AUDIO prompt and no capture; the stubs stay.
  final mic = voiceEnabled
      ? await resolveMicPorts(
          permission: ChannelMicPermission(),
          live: () => SafeAudioCapture(ChannelAudioCapture()),
        )
      : MicPorts(StubMicPermission(), StubAudioCapture(), live: false);
  input = InputPipeline(
    controller: controller,
    permission: mic.permission,
    capture: mic.capture,
    wakeWord: wakeWord,
    stt: GatedSpeechToText(chooseSpeechToText(
        fallback: StubSpeechToText(), modelDir: whisperModelDir(supportDir))),
    keyword: () => flow.interview.keyword,
  );
  if (voiceEnabled) await input.start();
  // Stop the microphone service when the engine detaches (app exit).
  AppLifecycleListener(onDetach: () => unawaited(input.dispose()));
  // Android only starts the microphone service while the app is on screen. A
  // start with the screen off fails (mic_start_failed), so retry on resume
  // (device test 2026-10-25). start() is a no-op while running.
  if (voiceEnabled) {
    AppLifecycleListener(onResume: () {
      if (input.status != InputStatus.running) unawaited(input.start());
    });
  }

  // Voice setup: the interview is answered by speaking, and "change my alarm
  // to 6:45" or "change my wake word to Vega" edit one value later. It
  // resumes at the saved step. Listening opens after each prompt only when
  // the microphone runs (on the stubs the prompts play alone).
  final setup = VoiceSetup(
    flow: flow,
    alarmStore: AlarmSettingsStore(store),
    saveAlarm: alarm.setAlarm,
    onKeywordChanged: input.refreshKeyword,
    listen: listenAfterPrompt,
    // Voice off: typed onboarding, no wake keyword step.
    typed: !voiceEnabled,
    // The restored chat may already end with the prompt (a restart before
    // the first answer); posting it again merged it into the same bubble.
    shownLast: voiceEnabled ? null : thread.endsWithAssistant,
  );
  await setup.load();

  // After the wake phrase: where long-term memory lives ("use my assistant
  // for memory" / "keep memory on the phone" later), then the Health Connect
  // question (voice first, then the system sheet). Each is asked once.
  // Voice off: no wake phrase is asked, so it counts as settled.
  bool phraseSettled() =>
      flow.interviewDone &&
      (!voiceEnabled || (!wakePhrase.asking && (wakePhrase.phrase != null || wakePhrase.declined)));
  final memoryMode = MemoryModeSetup(
    store: store,
    backend: longTerm,
    speak: flow.tts.speak,
    listen: listenAfterPrompt,
    ready: phraseSettled,
    assistantAvailable: () => server is HttpServerPort,
    typed: !voiceEnabled,
  );
  await memoryMode.load();
  final healthPort = ChannelHealthPort();
  final health = HealthSetup(
    port: healthPort,
    store: store,
    speak: flow.tts.speak,
    listen: listenAfterPrompt,
    ready: () => phraseSettled() && memoryMode.chosen && !memoryMode.asking,
    typed: !voiceEnabled,
  );
  await health.load();
  // One check-in question (mood, energy, sleep, 1 to 5) after the digest.
  final checkInStore = CheckInStore(store);
  final checkIn = CheckInSession(
      checkIns: checkInStore, speak: flow.tts.speak, listen: listenAfterPrompt, typed: !voiceEnabled);
  flow.afterDigest = checkIn.ask;

  // Council and assistant (docs/DESIGN.md). All of
  // it speaks through the controller's SpeechOutput with captions, so a wake
  // word or barge-in cancels it like the digest. Nothing here speaks over
  // the user, a reply or an open question ([quiet]).
  final linked = server is HttpServerPort;
  final councilSpeaker = CouncilSpeaker(
      speak: controller.speakAside,
      caption: (c) {
        controller.showCaption(c);
        if (!voiceEnabled) thread.attachSources(c);
      },
      trace: (lines) {
        if (!voiceEnabled) thread.attachTrace(lines);
      });
  // Typed chat: the council offer is a Yes / No bubble that closes with the
  // offer (a typed or tapped answer, or the timeout).
  final councilTimeout = councilOfferTimeout(voice: voiceEnabled);
  var councilOffers = 0;
  Future<bool> councilPrompt(String text) async {
    if (voiceEnabled || text != CouncilPrompt.offer) return controller.speakAside(text);
    final id = 'council-${++councilOffers}';
    thread.addOffer(text, id);
    Timer(councilTimeout, () => thread.closeOffer(id, OfferState.closed));
    return true;
  }

  late final CouncilFlow council;
  late final ApprovalFlow approval;
  late final AssistantBridge assistant;
  late final AnalysisFlow analysis;
  bool questionsOpen() =>
      setup.active || wakePhrase.asking || memoryMode.asking || health.asking || checkIn.asking;
  bool flowsBusy() => council.busy || approval.busy || assistant.busy || analysis.busy;
  bool quiet() => controller.idle && !questionsOpen() && !flowsBusy();
  void remember(String user, String answer) =>
      unawaited(shortTerm.addExchange(user: user, assistant: answer));

  council = CouncilFlow(
    server: server,
    speaker: councilSpeaker,
    speak: councilPrompt,
    listen: listenAfterPrompt,
    answerTimeout: councilTimeout,
    context: () => councilContextFrom(shortTerm),
    onAnswer: remember,
    // The answer waits only for the user or a reply, not for itself.
    quiet: () => controller.idle && !questionsOpen() && !approval.busy,
  );
  controller.afterAnswer = council.afterAnswer;
  approval = ApprovalFlow(server: server, speak: controller.speakAside, listen: listenAfterPrompt);
  assistant = AssistantBridge(
    server: server,
    approval: approval,
    speak: controller.speakAside,
    linked: () => linked,
    context: () => councilContextFrom(shortTerm).shortTermSummary,
    quiet: () => controller.idle && !questionsOpen() && !approval.busy,
    onExchange: remember,
  );
  analysis = AnalysisFlow(
    server: server,
    collect: () => collectAnalysisInput(
        checkIns: checkInStore, health: healthPort, today: DateTime.now(), imported: importedSignals),
    store: store,
    speaker: councilSpeaker,
  );

  // Settings through chat (app/spec_chat.dart): a change request becomes an
  // Approve / Cancel card; a not_understood or crisis answer goes on as a
  // normal turn. Setup and linking are not built yet (onSetup, onLink null).
  final spec = SpecChatFlow(
    server: server,
    thread: thread,
    redispatch: (text) => controller.dispatch(TextSubmitted(text)),
  );
  unawaited(noteSpecVersion(server, store, thread));

  // Assistant inbox: polled on foreground and after the wake word, only
  // while memory lives with the assistant; spoken at the next pause, or
  // folded into the morning digest.
  final inbox = AssistantInbox(
    server: server,
    store: store,
    speak: controller.speakAside,
    quiet: quiet,
    enabled: () => linked && memoryMode.mode == MemoryMode.assistant,
    onSpecRequest: (words) => unawaited(spec.proposeFromWords(words)),
  );
  await inbox.load();
  controller.addListener(inbox.onPause);
  controller.listenRequests.listen((_) => unawaited(inbox.poll()));
  AppLifecycleListener(onResume: () => unawaited(inbox.poll()));
  unawaited(inbox.poll());

  // The digest council runs on the server; its answer is spoken after the
  // digest, then the inbox items and the weekly 21-day analysis.
  flow
    ..councilContext = (() => councilContextFrom(shortTerm))
    ..councilSpeaker = councilSpeaker
    ..digestExtras = () async => await inbox.speakForDigest() && await analysis.weekly();

  // Ask before opening any view (PLAN.md rule 2026-10-28): a request
  // becomes a Yes / No offer; only a yes opens it through ViewHost.
  final viewOffer = ViewOffer(
    host: views,
    post: (prompt, id) {
      if (voiceEnabled) {
        unawaited(controller.speakAside(prompt).then((_) => listenAfterPrompt()));
      } else {
        thread.addOffer(prompt, id);
      }
    },
    resolved: (id, accepted) {
      thread.closeOffer(id, switch (accepted) {
        true => OfferState.accepted,
        false => OfferState.declined,
        null => OfferState.closed,
      });
      if (accepted == false) unawaited(controller.speakAside(CouncilPrompt.declined));
    },
  );

  // A typed meal line is logged, not answered: the preview and Save? show in
  // the chat; only that yes saves. No view opens (seeing the log is its own
  // offer above).
  final foodLog = ChatFoodLog(
    capture: LogCapture(
      kind: LogKind.food,
      server: server,
      store: logStore,
      date: () => dayKey(DateTime.now()),
    ),
    chat: ChatLogPort(
      say: thread.addAssistant,
      ask: thread.addOffer,
      close: (id, answered) => thread.closeOffer(id, switch (answered) {
        true => OfferState.accepted,
        false => OfferState.declined,
        null => OfferState.closed,
      }),
      note: thread.attachSources,
    ),
  );

  Future<void> offerNext() async {
    // Only when the interview is done and unanswered; never with voice off.
    if (voiceEnabled) await wakePhrase.offer();
    await memoryMode.offer();
    await health.offer();
  }

  // An open check-in question claims first, then the phrase step (its
  // answers and "change my wake phrase"), the memory and health questions
  // and their intents, then the interview. After any claimed answer the next
  // unanswered question is offered.
  controller.onSilence = setup.heardNothing;
  controller.setupHook = (text) {
    // An open approval takes every transcript (only a clear yes confirms),
    // then the council offer's yes or no.
    if (approval.claim(text)) return true;
    // A settings request, or the answer to its card. Not while a setup
    // question is open (its answers can name memory). With voice the card
    // still goes to the chat, and the voice says so.
    if (!questionsOpen() && spec.claim(text)) {
      if (voiceEnabled && parseSpecIntent(text) == SpecIntent.change) {
        unawaited(controller.speakAside(SpecLine.inChat));
      }
      return true;
    }
    // A typed meal line, or the answer to its Save? or calorie choice
    // (typed chat only). It goes before the view offer, which it cancels.
    if (!voiceEnabled && !setup.active && foodLog.claim(text)) {
      viewOffer.cancel();
      return true;
    }
    // An open view offer's yes or no, or a new view request.
    if (!setup.active && viewOffer.claim(text)) return true;
    if (!setup.active && council.claim(text)) return true;
    if (checkIn.claim(text)) return true;
    if (voiceEnabled && wakePhrase.claim(text)) {
      unawaited(wakePhrase.settled.then((_) => offerNext()));
      return true;
    }
    if (memoryMode.claim(text)) {
      unawaited(memoryMode.settled.then((_) => offerNext()));
      return true;
    }
    if (health.claim(text)) return true;
    if (!setup.active && (assistant.claim(text) || analysis.claim(text))) return true;
    final wasActive = setup.active;
    if (!setup.claim(text)) return false;
    if (wasActive) unawaited(setup.settled.then((_) => offerNext()));
    return true;
  };
  await setup.start();
  await offerNext();
}

/// App support directory (Android: the app's private files dir). A failing
/// lookup gives an empty base, so the model check fails and speech falls back.
Future<String> _supportDir() async {
  try {
    return (await getApplicationSupportDirectory()).path;
  } catch (e) {
    debugPrint('speech: support_dir_failed error=${e.runtimeType}');
    return '';
  }
}
