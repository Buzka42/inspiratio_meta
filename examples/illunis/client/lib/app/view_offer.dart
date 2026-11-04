/// Ask before opening any view (PLAN.md rule 2026-10-28, build plan B5).
///
/// A request ("show my logs") becomes one offer, "Open your logs? Yes / No",
/// posted to the chat thread. Only a yes, typed or tapped, mints an
/// [OfferToken], and [ViewHost.open] takes nothing else, so no view can open
/// without a yes. One offer is open at a time; a no, a new turn or
/// [ViewOffer.timeout] (90 s) without an answer cancels it. Logs carry
/// codes only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../voice/confirm_phrase.dart';
import 'view_requests.dart';

/// Proof of a yes for one view. Only [ViewOffer] can make one (the
/// constructor is private to this library), and [ViewHost] takes each once.
final class OfferToken {
  OfferToken._(this.request);
  final ViewRequest request;
  bool _spent = false;
}

/// Holds the one open view. [open] is the only way to show a view.
class ViewHost extends ChangeNotifier {
  ViewRequest? _open;

  /// The view on screen, or null.
  ViewRequest? get current => _open;

  /// Opens the view [token] was minted for. False for a token already used.
  bool open(OfferToken token) {
    if (token._spent) return false;
    token._spent = true;
    _open = token.request;
    notifyListeners();
    return true;
  }

  /// Closing needs no question.
  void close() {
    if (_open == null) return;
    _open = null;
    notifyListeners();
  }
}

typedef OfferPost = void Function(String prompt, String offerId);
typedef OfferResolved = void Function(String offerId, bool? accepted);
typedef OfferTimer = Timer Function(Duration d, void Function() f);

Timer _realTimer(Duration d, void Function() f) => Timer(d, f);

class ViewOffer {
  ViewOffer({
    required this.host,
    required this.post,
    this.resolved,
    OfferTimer? timer,
    void Function(String line)? log,
  })  : _timer = timer ?? _realTimer,
        _log = log ?? debugPrint;

  final ViewHost host;

  /// Shows the question (the chat thread's offer bubble).
  final OfferPost post;

  /// Called once per offer: true for yes, false for no, null for a cancel
  /// (timeout or a new turn).
  final OfferResolved? resolved;

  /// How long an offer waits for its answer (lead decision 2026-10-30): long
  /// enough to read the question and type a yes. The typed council offer
  /// waits as long (councilOfferTimeout in council_flow.dart).
  static const timeout = Duration(seconds: 90);
  final OfferTimer _timer;
  final void Function(String line) _log;

  ({String id, ViewRequest request})? _offer;
  Timer? _expiry;
  int _seq = 0;

  bool get offerOpen => _offer != null;
  String? get openOfferId => _offer?.id;

  /// For AppController.setupHook, after approval.claim. With an offer open,
  /// a yes opens the view, a no declines it, and anything else cancels the
  /// offer and is left for normal handling (or becomes a new offer when it
  /// is itself a view request). With none open, a view request becomes an
  /// offer. True when [text] was taken.
  bool claim(String text) {
    final open = _offer;
    if (open != null) {
      final a = parseOfferAnswer(text);
      if (a == true) {
        _close(true);
        host.open(OfferToken._(open.request));
        _log('view: opened kind=${open.request.kind.name}');
        return true;
      }
      if (a == false) {
        _close(false);
        _log('view: declined');
        return true;
      }
      _close(null);
      _log('view: offer_cancelled');
    }
    final req = parseViewRequest(text);
    if (req == null) return false;
    request(req);
    return true;
  }

  /// Offers [req] (a typed phrase, or later a server `offer_view`). A new
  /// offer replaces an open one, which is cancelled.
  void request(ViewRequest req) {
    if (_offer != null) _close(null);
    final id = 'view-${++_seq}';
    _offer = (id: id, request: req);
    post('Open ${req.label}?', id);
    _expiry = _timer(timeout, () {
      if (_offer?.id != id) return;
      _log('view: offer_timeout');
      _close(null);
    });
  }

  /// Cancels the open offer, if any (a new turn elsewhere).
  void cancel() {
    if (_offer != null) _close(null);
  }

  void _close(bool? accepted) {
    final id = _offer!.id;
    _expiry?.cancel();
    _expiry = null;
    _offer = null;
    resolved?.call(id, accepted);
  }
}
