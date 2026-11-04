/// The 21-day analysis (POST /analysis/21d; the server runs the council on
/// the structured findings only). Runs weekly, folded into the morning
/// digest, and on request ("how have I been doing"). The body is built by
/// lib/health/analysis_input.dart. Only the council's comment (number-
/// checked on the server) and the not-medical-advice notice are spoken; the
/// source titles show briefly.
///
/// The last run date is kept under [StoreKeys.analysisLastRun] and set only
/// when the server answered. Logs carry fixed codes only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../health/analysis_input.dart';
import '../health/daily_signals.dart' show dayKey, parseDayKey;
import '../voice/council_trigger.dart';
import 'aside.dart';
import 'council_flow.dart';
import 'persistence.dart';
import 'server_port.dart';

abstract final class AnalysisPrompt {
  static const intro = 'Here is your three-week look.';
  static const notEnough = 'I do not have enough check-ins or health data yet for a three-week look.';
  static const noComment = 'I have your three-week numbers, but no comment I can share right now.';
  static const unavailable = 'The three-week analysis is not available right now.';
}

class AnalysisFlow {
  AnalysisFlow({
    required this.server,
    required this.collect,
    required this.store,
    required this.speaker,
    this.interval = const Duration(days: 7),
    DateTime Function()? clock,
    AsideLog? log,
  })  : _clock = clock ?? DateTime.now,
        _log = log ?? debugPrint;

  final ServerPort server;

  /// Reads check-ins and Health Connect signals (collectAnalysisInput).
  final Future<AnalysisInput> Function() collect;
  final StateStore store;
  final CouncilSpeaker speaker;
  final Duration interval;
  final DateTime Function() _clock;
  final AsideLog _log;

  bool _running = false;
  Future<void> _queue = Future.value();

  bool get busy => _running;
  Future<void> get settled => _queue;

  /// Takes "how have I been doing" and the like.
  bool claim(String text) {
    if (!isAnalysisRequest(text)) return false;
    _queue = _queue.then((_) => run(requested: true));
    return true;
  }

  /// True when the last run is [interval] or more ago (or never).
  Future<bool> due() async {
    final last = parseDayKey(await store.getString(StoreKeys.analysisLastRun));
    if (last == null) return true;
    final now = _clock();
    return DateTime(now.year, now.month, now.day).difference(last).inDays >= interval.inDays;
  }

  /// The weekly run, for the end of the morning digest. Silent when there
  /// is nothing to say. False only when the user interrupted the speech.
  Future<bool> weekly() async {
    try {
      if (!await due()) return true;
    } catch (e) {
      _log('analysis: due_failed error=${e.runtimeType}');
      return true;
    }
    return run(requested: false);
  }

  /// One run. [requested] speaks every outcome; the weekly run speaks only
  /// a real comment.
  Future<bool> run({required bool requested}) async {
    if (_running) return true;
    _running = true;
    try {
      final input = await collect();
      if (input.isEmpty) {
        _log('analysis: no_input');
        return requested ? await speaker.speak(AnalysisPrompt.notEnough) : true;
      }
      final AnalysisResult r;
      try {
        r = await server.analysis21d(input.toJson());
      } catch (e) {
        _log('analysis: failed code=${asideCode(e)}');
        return requested ? await speaker.speak(AnalysisPrompt.unavailable) : true;
      }
      await store.setString(StoreKeys.analysisLastRun, dayKey(_clock()));
      if (r.crisis) {
        final t = r.text;
        _log('analysis: crisis');
        return t == null || t.trim().isEmpty ? true : await speaker.speak(t);
      }
      final comment = r.comment;
      if (comment == null) {
        _log('analysis: no_comment code=${r.commentCode ?? 'none'}');
        if (!requested) return true;
        return await speaker.speak(r.commentCode == 'nothing_to_comment' ? AnalysisPrompt.notEnough : AnalysisPrompt.noComment);
      }
      _log('analysis: comment sources=${r.sources.length}');
      final notice = r.notice;
      final text = notice == null || comment.contains(notice) ? comment : '$comment $notice';
      return await speaker.sayText('${AnalysisPrompt.intro} $text', medical: r.medical, sources: r.sources);
    } catch (e) {
      _log('analysis: failed error=${e.runtimeType}');
      return true;
    } finally {
      _running = false;
    }
  }
}
