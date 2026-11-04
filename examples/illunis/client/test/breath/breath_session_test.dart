// The session state machine: count-in, phase timing, pause, stop, cues,
// hold rules, and the cue voice with a fake engine (no audio). Synthetic
// techniques plus the synced library.
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/breath/breath_session.dart';
import 'package:illunis_client/breath/breath_voice.dart';
import 'package:illunis_client/breath/technique.dart';
import 'package:illunis_client/output/kokoro/kokoro_licence.dart';
import 'package:illunis_client/output/speech_fakes.dart';

import 'breath_fixtures.dart';

void main() {
  group('count-in', () {
    test('three cycles before the timer starts', () {
      final s = BreathSession(synthetic()); // 4 s in, 6 s out
      expect(s.cycleS, 10);
      expect(s.countInS, 30);
      expect(s.stage, BreathStage.countIn);
      expect(s.countInCycle, 1);
      s.advance(10.5);
      expect(s.countInCycle, 2);
      s.advance(19);
      expect(s.countInCycle, 3);
      expect(s.elapsedS, 0);
      s.advance(0.5);
      expect(s.stage, BreathStage.running);
      expect(s.countInCycle, isNull);
      expect(s.elapsedS, 0);
    });
  });

  group('timing', () {
    test('phases loop with their seconds', () {
      final s = BreathSession(synthetic());
      expect(s.phase.kind, BreathPhaseKind.inhale);
      s.advance(2);
      expect(s.phaseProgress, closeTo(0.5, 1e-9));
      expect(s.phaseRemainingS, closeTo(2, 1e-9));
      s.advance(2);
      expect(s.phase.kind, BreathPhaseKind.exhale);
      s.advance(6);
      expect(s.phase.kind, BreathPhaseKind.inhale);
    });

    test('the visual fills on the inhale and empties on the exhale', () {
      final s = BreathSession(synthetic());
      expect(s.level, closeTo(0, 1e-9));
      s.advance(2);
      expect(s.level, closeTo(0.5, 1e-9));
      s.advance(1.999);
      expect(s.level, greaterThan(0.99));
      s.advance(3.001);
      expect(s.level, closeTo(0.5, 1e-9));
    });

    test('the session ends after duration_s on the timer', () {
      final s = BreathSession(synthetic(durationS: 60));
      s.advance(30 + 59);
      expect(s.stage, BreathStage.running);
      expect(s.remainingS, closeTo(1, 1e-9));
      s.advance(5);
      expect(s.stage, BreathStage.ended);
      expect(s.end, BreathEnd.completed);
      expect(s.elapsedS, 60);
      expect(s.endText, 'Synthetic end.');
    });

    test('a technique with no playable timing cannot start', () {
      final lib = loadAssetLibrary();
      expect(() => BreathSession(lib.byId('holotropic')!), throwsArgumentError);
      expect(() => BreathSession(lib.byId('kapalabhati')!), throwsArgumentError);
      expect(() => BreathSession(synthetic(available: false)), throwsArgumentError);
    });
  });

  group('pause and stop', () {
    test('pause holds the phase position and the timer; resume carries on', () {
      final s = BreathSession(synthetic());
      s.advance(32.5); // running, 2.5 s into the inhale
      final level = s.level;
      s.pause();
      expect(s.paused, isTrue);
      expect(s.advance(100), isEmpty);
      expect(s.phase.kind, BreathPhaseKind.inhale);
      expect(s.phaseProgress, closeTo(2.5 / 4, 1e-9));
      expect(s.elapsedS, closeTo(2.5, 1e-9));
      expect(s.level, level);
      s.resume();
      s.advance(1.5);
      expect(s.phase.kind, BreathPhaseKind.exhale);
      expect(s.elapsedS, closeTo(4, 1e-9));
    });

    test('stop ends at once with the end copy, even while paused', () {
      final s = BreathSession(synthetic(cues: const [Cue(atS: 5, text: 'Synthetic cue.', speak: true)]));
      s.advance(31);
      s.pause();
      s.stop();
      expect(s.stage, BreathStage.ended);
      expect(s.end, BreathEnd.stopped);
      expect(s.paused, isFalse);
      expect(s.endText, 'Synthetic end.');
      expect(s.advance(100), isEmpty);
      expect(s.firedCues, isEmpty);
      s.stop();
      expect(s.end, BreathEnd.stopped);
    });
  });

  group('cues', () {
    const cues = [
      Cue(atS: 0, text: 'Synthetic first.', speak: true),
      Cue(atS: 10, text: 'Synthetic second.', speak: true),
      Cue(atS: 20, text: 'Synthetic shown only.', speak: false),
      Cue(atS: 60, text: 'Synthetic too late.', speak: true),
    ];

    test('fire at at_s on the session timer, once each, never in the count-in', () {
      final s = BreathSession(synthetic(cues: cues, durationS: 60));
      expect(s.advance(29.9), isEmpty);
      expect(s.advance(0.1).map((c) => c.text), ['Synthetic first.']);
      expect(s.advance(9.9), isEmpty);
      expect(s.advance(0.1).map((c) => c.text), ['Synthetic second.']);
      expect(s.advance(0.1), isEmpty);
      expect(s.currentCue?.text, 'Synthetic second.');
      expect(s.advance(100).map((c) => c.text), ['Synthetic shown only.']);
      expect(s.stage, BreathStage.ended);
      expect(s.firedCues.length, 3);
    });

    test('a large step fires every passed cue in order', () {
      final s = BreathSession(synthetic(cues: cues, durationS: 60));
      expect(s.advance(55).map((c) => c.atS), [0, 10, 20]);
    });

    test('library cues fire at their at_s', () {
      final box = loadAssetLibrary().byId('box_breathing')!;
      final s = BreathSession(box);
      final fired = <(double, int)>[];
      for (var i = 0; i < 4000 && s.stage != BreathStage.ended; i++) {
        for (final c in s.advance(0.1)) {
          fired.add((s.elapsedS, c.atS));
        }
      }
      expect(fired.map((f) => f.$2), box.cues.map((c) => c.atS));
      for (final (t, at) in fired) {
        expect(t, closeTo(at.toDouble(), 0.11));
      }
    });
  });

  group('hold rules', () {
    test('no empty-lung hold, basic holds capped at 4 s', () {
      final t = synthetic(phases: const [
        BreathPhase(BreathPhaseKind.inhale, 4),
        BreathPhase(BreathPhaseKind.hold, 7),
        BreathPhase(BreathPhaseKind.exhale, 6),
        BreathPhase(BreathPhaseKind.holdEmpty, 15),
      ]);
      final s = BreathSession(t);
      expect(s.phases.map((p) => (p.kind, p.seconds)),
          [(BreathPhaseKind.inhale, 4.0), (BreathPhaseKind.hold, 4.0), (BreathPhaseKind.exhale, 6.0)]);
    });

    test('an advanced technique keeps a long hold but never an empty-lung one', () {
      final t = synthetic(level: TechniqueLevel.advanced, phases: const [
        BreathPhase(BreathPhaseKind.inhale, 4),
        BreathPhase(BreathPhaseKind.hold, 7),
        BreathPhase(BreathPhaseKind.exhale, 6),
        BreathPhase(BreathPhaseKind.holdEmpty, 15),
      ]);
      expect(safePhases(t).map((p) => p.kind), isNot(contains(BreathPhaseKind.holdEmpty)));
      expect(safePhases(t)[1].seconds, 7);
    });

    test('every basic library technique plays holds of 4 s or less', () {
      for (final t in loadAssetLibrary().basics()) {
        for (final p in safePhases(t)) {
          expect(p.kind, isNot(BreathPhaseKind.holdEmpty), reason: t.id);
          if (p.kind.isHold) expect(p.seconds, lessThanOrEqualTo(maxBasicHoldS), reason: t.id);
        }
      }
    });

    test('the visual stays still during a hold', () {
      final s = BreathSession(loadAssetLibrary().byId('box_breathing')!);
      s.advance(4.5); // into the first hold, after a full inhale
      final a = s.level;
      s.advance(2);
      expect(s.phase.kind, BreathPhaseKind.hold);
      expect(s.level, a);
      expect(a, closeTo(1, 1e-9));
      s.advance(6); // second hold, after the exhale
      expect(s.phase.kind, BreathPhaseKind.hold);
      expect(s.level, closeTo(0, 1e-9));
    });
  });

  group('voice', () {
    const spoken = Cue(atS: 0, text: 'Synthetic spoken.', speak: true);
    const shown = Cue(atS: 0, text: 'Synthetic shown.', speak: false);

    test('speaks only cues marked speak, when allowed', () async {
      final e = FakeTtsEngine();
      final v = BreathVoice(engine: e, allowed: true);
      expect(v.canSpeak, isTrue);
      expect(v.speak(shown), isFalse);
      expect(v.speak(spoken), isTrue);
      await pumpEventQueue();
      expect(e.played, ['Synthetic spoken.']);
    });

    test('without the licence gate nothing is spoken', () async {
      final e = FakeTtsEngine();
      for (final v in [
        if (!kokoroGplCheckedFlag) BreathVoice(engine: e),
        BreathVoice(engine: e, allowed: false),
        BreathVoice.silent(),
      ]) {
        expect(v.canSpeak, isFalse);
        expect(v.speak(spoken), isFalse);
      }
      await pumpEventQueue();
      expect(e.trace, isEmpty);
    });

    test('stop silences the current cue and drops queued ones', () async {
      final e = FakeTtsEngine(autoFinish: false);
      final v = BreathVoice(engine: e, allowed: true);
      v.speak(spoken);
      v.speak(const Cue(atS: 1, text: 'Synthetic queued.', speak: true));
      await pumpEventQueue();
      expect(e.isPlaying, isTrue);
      await v.stop();
      await pumpEventQueue();
      expect(e.stops, 1);
      expect(e.trace.where((t) => t.contains('queued')), isEmpty);
    });
  });
}
