/// Typed meal logging from the chat (build plan B6 with the ask-first rule,
/// PLAN.md 2026-10-28). A line that says what the user ate ("I had 200 g
/// cooked rice and two eggs for lunch") is matched by plain code and goes to
/// POST /log/parse, not to the chat reply. No view opens: the preview (each
/// item with its calories, "est." on an estimate, and the total) shows in
/// the chat with "Save? Yes / No", and only that yes writes it to
/// [LogStore], where the food view lists it. A calorie mismatch shows both
/// numbers with "Keep mine" and "Use" first; nothing is saved before the
/// pick and the yes. Asking to see the log ("show my food log") stays a
/// view offer (view_offer.dart). Logs carry fixed codes only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/server_port.dart' show FoodChoice;
import '../app/view_requests.dart';
import '../voice/confirm_phrase.dart';
import 'log_capture.dart';
import 'log_entry.dart';
import 'log_math.dart' show numText;
import 'views/food_view.dart';

/// Verbs that only ever mean eating or drinking.
final _ateVerb = RegExp(r'^(?:i |we )?(?:have )?(?:just |already )?(?:ate|eaten|drank|drunk)\b');

/// "had": food only with a food signal ("I had a headache" is not a meal).
final _hadVerb = RegExp(r'^(?:i |we )?(?:have )?(?:just |already )?had\b');

/// "for lunch I had ...", "breakfast was ...", "lunch: ...".
final _mealLead = RegExp(r'^(?:for |at )?(?:my )?(breakfast|lunch|dinner|supper|snack|brunch)\b');

/// "log 2 eggs and toast", "add a banana": a log line with its contents.
final _logLead = RegExp(r'^(?:please )?(?:log|add|record|track)\b');

final _mealWord = RegExp(r'\b(?:breakfast|lunch|dinner|supper|snack|brunch)\b');

final _unitWord = RegExp(r'\d\s*(?:g|grams?|kg|ml|l|kcal|cal|calories)\b|'
    r'\b(?:kcal|calories|cups?|slices?|bowls?|plates?|pieces?|servings?|portions?|tbsp|tsp|tablespoons?|'
    r'teaspoons?|glass(?:es)?|mugs?|handfuls?|scoops?|cans?|bottles?)\b');

const _foods = {
  'rice', 'egg', 'eggs', 'banana', 'bananas', 'apple', 'apples', 'orange', 'oranges', 'bread', 'toast', 'oats',
  'oatmeal', 'porridge', 'cereal', 'granola', 'muesli', 'yogurt', 'yoghurt', 'milk', 'coffee', 'tea', 'latte',
  'cappuccino', 'juice', 'smoothie', 'shake', 'chicken', 'beef', 'pork', 'lamb', 'fish', 'salmon', 'tuna', 'steak',
  'pasta', 'spaghetti', 'noodles', 'pizza', 'burger', 'sandwich', 'wrap', 'salad', 'soup', 'cheese', 'butter',
  'potato', 'potatoes', 'fries', 'chips', 'crisps', 'beans', 'lentils', 'tofu', 'avocado', 'berries', 'grapes',
  'nuts', 'almonds', 'peanut', 'chocolate', 'cake', 'biscuit', 'biscuits', 'cookie', 'cookies', 'muffin',
  'croissant', 'bagel', 'sushi', 'curry', 'vegetables', 'veg', 'broccoli', 'carrots', 'ham', 'bacon', 'sausage',
  'sausages', 'pancakes', 'waffles', 'honey', 'jam', 'hummus', 'quinoa', 'couscous', 'fruit', 'ice cream',
};

String _normalise(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r"[’'`]"), '')
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\bive\b'), 'i have')
    .replaceAll(RegExp(r'\bweve\b'), 'we have');

bool _foodSignal(String t) =>
    _mealWord.hasMatch(t) || _unitWord.hasMatch(t) || t.split(' ').any(_foods.contains) || t.contains('ice cream');

/// True for a line that says what the user ate or drank, by plain code.
/// A question, a view request ("log my lunch" asks for the food log) and
/// an empty "log" are not meal lines.
bool isMealLine(String text) {
  if (text.contains('?') || parseViewRequest(text) != null) return false;
  final t = _normalise(text);
  if (t.isEmpty || RegExp(r'^(?:how|what|why|when|where|which|who|should|can|could|would|is|are|do|does|did)\b').hasMatch(t)) {
    return false;
  }
  if (_ateVerb.hasMatch(t)) return t.split(' ').length > 1;
  if (_hadVerb.hasMatch(t)) return _foodSignal(t.replaceFirst(_hadVerb, ''));
  if (_mealLead.firstMatch(t) case final m?) return _foodSignal(t.substring(m.end));
  if (_logLead.hasMatch(t)) return _foodSignal(t.replaceFirst(_logLead, ''));
  return false;
}

abstract final class ChatLogText {
  static const saved = 'Saved to your food log.';
  static const savePrompt = CaptureText.savePrompt;
  static const keepMine = 'Keep mine';
  static const use = 'Use';

  /// The tapped labels of one mismatch row.
  static String keepLabel(FoodChoice c) => '$keepMine (${numText(c.userValue.toDouble())})';
  static String useLabel(FoodChoice c) => '$use ${numText(c.foundValue.toDouble())}';
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The preview as chat text: the meal, one line per item with its amount
/// and calories ("est." on an estimate), and the entry's total.
String foodPreviewText(FoodEntry e) => [
      if (e.meal != null) _cap(e.meal!),
      for (final i in e.items) [_cap(i.name), if (foodAmount(i).isNotEmpty) foodAmount(i)].join(' · '),
      'Total: ${foodTotal([e])}',
    ].join('\n');

/// One mismatch as chat text: both numbers and where the found one is from.
String foodChoiceText(FoodEntry e, FoodChoice c) {
  final name = c.itemIndex < e.items.length ? _cap(e.items[c.itemIndex].name) : 'Item';
  final host = c.sourceUrl == null ? null : Uri.tryParse(c.sourceUrl!)?.host;
  return [
    CaptureText.verify,
    '$name: you wrote ${numText(c.userValue.toDouble())} kcal. '
        '${c.sourceTitle ?? 'The source'} lists ${numText(c.foundValue.toDouble())} kcal.',
    if (host != null && host.isNotEmpty) host,
  ].join('\n');
}

/// Where the flow writes in the chat. In the app these are the
/// [ChatThread]'s methods.
class ChatLogPort {
  const ChatLogPort({required this.say, required this.ask, required this.close, this.note});

  /// One assistant line ("Saved to your food log.").
  final void Function(String text) say;

  /// A question with actions: Yes / No when [choices] is null.
  final void Function(String text, String offerId, {List<String>? choices}) ask;

  /// Marks an asked question answered (true), declined (false) or closed.
  final void Function(String offerId, bool? answered) close;

  /// A note under the last line ("Checked against ...").
  final void Function(String text)? note;
}

class ChatFoodLog {
  ChatFoodLog({required this.capture, required this.chat, void Function(String line)? log})
      : _log = log ?? debugPrint {
    capture.addListener(_onState);
  }

  /// A food [LogCapture] (its store is the one the food view reads).
  final LogCapture capture;
  final ChatLogPort chat;
  final void Function(String line) _log;

  String? _offer;
  int _seq = 0;

  /// True while a preview or a choice waits for its answer, or a line is
  /// being read.
  bool get active => switch (capture.state) {
        CapturePreview() || CaptureChoice() || CaptureReading() => true,
        _ => false,
      };

  /// For AppController.setupHook. With a preview open: yes saves, no
  /// discards. With a choice open: "Keep mine" / "Use ..." settle the row,
  /// "mine" / "source" settle every row, no discards. Anything else drops
  /// the open entry unsaved and, when it is itself a meal line, logs that
  /// line instead. True when [text] was taken.
  bool claim(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final s = capture.state;
    if (s is CapturePreview) {
      final a = parseOfferAnswer(t);
      if (a != null) {
        _closeOffer(a);
        unawaited(capture.answer(a));
        return true;
      }
    } else if (s is CaptureChoice) {
      final pick = _pick(t, s);
      if (pick != null) {
        _closeOffer(true);
        pick();
        return true;
      }
    }
    if (active) cancel();
    if (!isMealLine(t)) return false;
    _log('log: chat_meal');
    unawaited(capture.submit(t));
    return true;
  }

  /// Drops whatever is open, unsaved and without a message (a new turn).
  void cancel() {
    _closeOffer(null);
    capture.reset();
  }

  void dispose() => capture.removeListener(_onState);

  /// The answer to the first open mismatch row, or null when [t] is none.
  VoidCallback? _pick(String t, CaptureChoice s) {
    final first = s.choices.first;
    final w = normaliseSpoken(t);
    if (w == normaliseSpoken(ChatLogText.keepLabel(first)) || w == 'keep mine' || w == 'keep') {
      return () => capture.chooseOne(first, useFound: false);
    }
    if (w == normaliseSpoken(ChatLogText.useLabel(first)) || w == 'use' || w == 'use found' || w == 'use theirs') {
      return () => capture.chooseOne(first, useFound: true);
    }
    final all = parseChoiceAnswer(t);
    if (all != null) return () => capture.chooseAll(useFound: all == ChoiceAnswer.source);
    if (parseOfferAnswer(t) == false || w == 'discard') return capture.discardChoice;
    return null;
  }

  void _closeOffer(bool? answered) {
    final id = _offer;
    if (id == null) return;
    _offer = null;
    chat.close(id, answered);
  }

  String _ask(String text, {List<String>? choices}) {
    final id = 'log-${++_seq}';
    _offer = id;
    chat.ask(text, id, choices: choices);
    return id;
  }

  void _onState() {
    switch (capture.state) {
      case CaptureIdle() || CaptureReading():
        return;
      case CaptureMessage(:final text):
        chat.say(text == CaptureText.saved ? ChatLogText.saved : text);
      case CaptureCrisis(:final referral):
        chat.say(referral);
      case CapturePreview(:final entry, :final checkedAgainst):
        if (entry is! FoodEntry) return;
        chat.say(foodPreviewText(entry));
        if (checkedAgainst != null) chat.note?.call(CaptureText.checkedAgainst(checkedAgainst));
        _ask(ChatLogText.savePrompt);
      case CaptureChoice(:final entry, :final choices):
        if (entry is! FoodEntry) return;
        final c = choices.first;
        _ask(foodChoiceText(entry, c), choices: [ChatLogText.keepLabel(c), ChatLogText.useLabel(c)]);
    }
  }
}
