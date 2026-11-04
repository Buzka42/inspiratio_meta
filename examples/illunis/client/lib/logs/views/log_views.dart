/// Which widget a log [ViewRequest] opens. Called by IllunisRoot only for
/// the view ViewHost holds, which exists only after a yes (OfferToken).
library;

import 'package:flutter/widgets.dart';

import '../../app/view_requests.dart';
import 'activity_view.dart';
import 'cardio_view.dart';
import 'day_view.dart';
import 'food_view.dart';
import 'log_frame.dart';
import 'run_view.dart';
import 'strength_view.dart';
import 'wellbeing_view.dart';

export 'log_frame.dart' show LogViews;

/// The log view for [req], or null when [req] is not a log view or the app
/// has no [deps] (the caller then shows its placeholder).
Widget? logViewFor(ViewRequest req, LogViews? deps, VoidCallback onClose) {
  if (deps == null) return null;
  return switch (req.kind) {
    ViewKind.logs => LogsDayView(deps: deps, onClose: onClose),
    ViewKind.food => FoodView(deps: deps, onClose: onClose),
    ViewKind.activity => ActivityView(deps: deps, onClose: onClose),
    ViewKind.strength => StrengthView(deps: deps, onClose: onClose),
    ViewKind.run => RunView(deps: deps, onClose: onClose),
    ViewKind.cardio => CardioView(deps: deps, onClose: onClose),
    ViewKind.wellbeing => WellbeingView(deps: deps, onClose: onClose),
    _ => null,
  };
}
