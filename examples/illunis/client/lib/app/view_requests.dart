/// Typed (or spoken) requests for a view, matched by plain code like
/// view_intents.dart. A match never opens anything: it becomes an offer
/// (view_offer.dart) that needs a yes first (PLAN.md rule 2026-10-28).
library;

/// The views a request can name. Breathwork opens a placeholder until its
/// contents are built (build plan step 4). The log kinds open the views in
/// lib/logs/views/; [logs] is the day's overview of all of them.
enum ViewKind {
  logs('your logs'),
  food('your food log'),
  activity('your activity log'),
  strength('your strength log'),
  run('your run log'),
  cardio('your cardio log'),
  wellbeing('your wellbeing view'),
  breathwork('breathwork');

  const ViewKind(this.label);

  /// Shown in the offer: "Open your logs?".
  final String label;
}

/// A matched request: the view and how the offer names it ("your strength
/// log" when a log type was named).
class ViewRequest {
  const ViewRequest(this.kind, this.label);
  final ViewKind kind;
  final String label;

  @override
  bool operator ==(Object other) => other is ViewRequest && other.kind == kind && other.label == label;
  @override
  int get hashCode => Object.hash(kind, label);
}

/// A breathwork request that named a technique ("do box breathing").
/// [technique] is the name as typed (normalised); the breath view finds it
/// in the library by name or alias only.
class BreathRequest extends ViewRequest {
  const BreathRequest(this.technique) : super(ViewKind.breathwork, technique);
  final String technique;

  @override
  bool operator ==(Object other) => other is BreathRequest && other.technique == technique;
  @override
  int get hashCode => Object.hash(kind, technique);
}

/// Normalised technique names and aliases, registered by the breath library
/// once it loads (breath/breath_wiring.dart). Empty until then.
final _breathNames = <String>{};

/// Replaces the technique names a request may name.
void registerBreathNames(Iterable<String> names) => _breathNames
  ..clear()
  ..addAll(names);

const _verb = r'(?:show|open|see|view|display|bring up|pull up|go to|start|begin)(?: me)?';

final _log = RegExp('^(?:i want to |i would like to |let me )?$_verb (?:my |the )?'
    r'(?:(food|meal|activity|training|workout|strength|lifting|weights|run|running|cardio|wearable|sleep|wellbeing|health) )?'
    r'(?:logs?|view|data)$');

// "log my run", "add a meal": opens that log (after a yes) to type the entry.
final _logCapture = RegExp(r'^(?:i want to |i would like to |let me |i need to )?(?:log|add|record) '
    r'(?:my |a |an |the |some |today s )?'
    r'(food|meal|breakfast|lunch|dinner|snack|activity|walk|training|workout|strength|lifting|weights|run|running|cardio)'
    r'(?: session| entry| log)?$');

const _logTypes = {
  'food': ViewKind.food, 'meal': ViewKind.food, 'breakfast': ViewKind.food, 'lunch': ViewKind.food,
  'dinner': ViewKind.food, 'snack': ViewKind.food,
  'activity': ViewKind.activity, 'walk': ViewKind.activity,
  'training': ViewKind.strength, 'workout': ViewKind.strength, 'strength': ViewKind.strength,
  'lifting': ViewKind.strength, 'weights': ViewKind.strength,
  'run': ViewKind.run, 'running': ViewKind.run,
  'cardio': ViewKind.cardio,
  'wearable': ViewKind.wellbeing, 'sleep': ViewKind.wellbeing, 'wellbeing': ViewKind.wellbeing,
  'health': ViewKind.wellbeing,
};

final _breath = RegExp('^(?:i want to |i would like to |let me )?(?:$_verb |do )(?:my |the |a |some )?'
    r'(?:breathwork|breath work|breathing)(?: exercises?| library| session)?$');

final _breathNamed = RegExp('^(?:i want to |i would like to |let me )?(?:$_verb |do |try |practise |practice )'
    r'(?:my |the |a |an |some )?(.+?)(?: session| exercise| practice)?$');

String _normalise(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z\s]"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r'^(please |can you |could you |would you )'), '')
    .replaceFirst(RegExp(r' please$'), '');

/// "show my logs", "open the strength log", "start breathwork". Null when
/// [text] is not a view request (a question about breathwork is not one).
ViewRequest? parseViewRequest(String text) {
  final t = _normalise(text);
  final log = _log.firstMatch(t) ?? _logCapture.firstMatch(t);
  final logType = log?.group(1);
  if (logType != null) return ViewRequest(_logTypes[logType]!, _logTypes[logType]!.label);
  // "show my logs" is the overview; a bare "show my view" or "data" is not a log request.
  if (log != null && RegExp(r'logs?$').hasMatch(t)) return const ViewRequest(ViewKind.logs, 'your logs');
  if (_breath.hasMatch(t)) return const ViewRequest(ViewKind.breathwork, 'breathwork');
  final named = _breathNamed.firstMatch(t)?.group(1);
  if (named != null && _breathNames.contains(named)) return BreathRequest(named);
  return null;
}
