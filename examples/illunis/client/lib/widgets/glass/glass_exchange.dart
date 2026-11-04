/// The latest exchange, straight on the sky (no plate), centred above the
/// input (UI_PLAN UI-2): your own line small in the sans and ink2, the reply
/// in the serif, notes (sources, the not-medical-advice line) under a
/// hairline, then the council trace ("How the council answered", open by
/// default, a tap folds it), and an offer's Yes / No under a hairline at the
/// bottom. It
/// grows to fit and never scrolls. When it would not fit, the fit ladder:
/// the reply steps 22, 20, 18 px (never back up within an exchange), then
/// your line goes, then the inset tightens, and only then does the whole
/// block scale down. Text is never clipped.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/chat_thread.dart';
import '../../app/council_flow.dart' show councilTraceTitle, notMedicalAdviceLine;
import '../../ui/icons.dart';
import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';
import 'glass_actions.dart';
import 'glass_surface.dart';

/// Layout numbers shared by the layout and its measurement.
abstract final class ExchangeMetrics {
  static const double maxWidth = 560;

  /// Room for two 48 px actions with their labels.
  static const double minOfferWidth = 232;
  static const EdgeInsets inset = EdgeInsets.fromLTRB(Space.inset, Space.gutter, Space.inset, 18);
  static const EdgeInsets tightInset = EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.s12);

  /// Your line, then the reply: a clear step between the two voices.
  static const double echoGap = Space.s12;
  static const double paragraphGap = Space.s12;
  static const double notesGap = Space.s12;
  static const double noteGap = Space.s4;

  /// The trace toggle's chevron and the gap before it.
  static const double traceGlyph = 16;
  static const double traceGlyphGap = Space.s4;

  /// Where a short reply sits: a little above the middle of the open sky.
  static const Alignment place = Alignment(0, -0.12);
}

/// What one exchange shows, read from its thread entries.
@immutable
class ExchangeContent {
  const ExchangeContent(
      {this.echo, this.paragraphs = const [], this.notes = const [], this.trace = const [], this.offerId, this.offerChoices});

  /// The user's own line.
  final String? echo;

  /// Reply text, one paragraph per assistant entry, without the disclaimer.
  final List<String> paragraphs;

  /// Sources and the disclaimer, each its own note line.
  final List<String> notes;

  /// The council trace lines of the exchange's council answer, if any.
  final List<String> trace;

  /// The open offer's id (Yes / No show), if any.
  final String? offerId;

  /// The open offer's own answers in place of Yes / No, if it has them.
  final List<String>? offerChoices;

  /// The action labels under the open offer.
  List<String> get offerLabels => offerChoices ?? const ['Yes', 'No'];

  bool get hasNotes => notes.isNotEmpty || trace.isNotEmpty;

  factory ExchangeContent.of(List<ChatEntry> entries) {
    String? echo;
    final paragraphs = <String>[], notes = <String>[];
    String? offer;
    List<String>? choices;
    var trace = const <String>[];
    var disclaimer = false;
    for (final e in entries) {
      if (e.role == ChatRole.user) {
        echo = e.text;
        continue;
      }
      var text = e.text;
      if (text.contains(notMedicalAdviceLine)) {
        text = text.replaceAll(notMedicalAdviceLine, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
        disclaimer = true;
      }
      if (text.isNotEmpty) paragraphs.add(text);
      if (e.sources case final s? when !notes.contains(s)) notes.add(s);
      if (e.offer case final o? when o.isOpen) {
        offer = o.id;
        choices = o.choices;
      }
      if (e.trace case final t?) trace = t;
    }
    if (disclaimer) notes.add(notMedicalAdviceLine);
    return ExchangeContent(
        echo: echo, paragraphs: paragraphs, notes: notes, trace: trace, offerId: offer, offerChoices: choices);
  }
}

/// A rung of the fit ladder.
@immutable
class ExchangeFit {
  const ExchangeFit({required this.size, required this.echo, required this.inset, required this.width, required this.height});
  final double size;
  final bool echo;
  final EdgeInsets inset;
  final double width, height;
}

/// The reply size an exchange has reached; it only goes down within one.
class FitMemory {
  Object? exchange;
  double cap = TypeScale.replySteps.first.$1;

  double capFor(Object exchange) {
    if (this.exchange != exchange) {
      this.exchange = exchange;
      cap = TypeScale.replySteps.first.$1;
    }
    return cap;
  }
}

const _anyColour = SkyColors.space; // measurement only; colour never changes metrics

double _textHeight(String text, TextStyle style, double width, TextScaler scaler) {
  final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
    ..layout(maxWidth: width);
  final h = p.height;
  p.dispose();
  return h;
}

double _textWidth(String text, TextStyle style, TextScaler scaler) {
  final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
    ..layout();
  final w = p.maxIntrinsicWidth;
  p.dispose();
  return w;
}

/// Height of the Yes / No row: a 48 px target or the label's line, padded.
/// With [labels] in cells of [width] in all, the tallest label as it wraps.
double offerHeight(TextScaler scaler, {List<String> labels = const ['Yes'], double width = double.infinity}) {
  final cell = (width / labels.length - 2 * Space.s8).clamp(1.0, double.infinity);
  final tallest = labels.map((l) => _textHeight(l, TypeScale.label(_anyColour), cell, scaler)).fold(0.0, math.max);
  return math.max(Space.target, tallest + 2 * Space.s12);
}

/// The width that keeps every label of the action row on one line.
double offerWidth(List<String> labels, TextScaler scaler) =>
    labels.length * labels.map((l) => _textWidth(l, TypeScale.label(_anyColour), scaler) + 2 * Space.s8 + 1).fold(0.0, math.max);

/// Height of the trace toggle row at [inner] width: a 48 px target or the
/// title's lines beside the chevron, padded.
double traceToggleHeight(double inner, TextScaler scaler) {
  final room = inner - ExchangeMetrics.traceGlyph - ExchangeMetrics.traceGlyphGap;
  final title = _textHeight(councilTraceTitle, TypeScale.label(_anyColour), room, scaler);
  return math.max(Space.target, math.max(title, ExchangeMetrics.traceGlyph) + 2 * Space.s12);
}

/// Width and height of [c] at reply [size], with or without the [echo],
/// with [inset], at most [maxWidth] wide, with the trace open or folded.
ExchangeFit measureExchange(ExchangeContent c,
    {required double size, required bool echo, required EdgeInsets inset, required double maxWidth,
    required TextScaler scaler, double hair = 1, bool traceOpen = true}) {
  final reply = TypeScale.reply(_anyColour, size: size);
  final body = TypeScale.body(_anyColour), note = TypeScale.note(_anyColour);
  final showEcho = echo && c.echo != null;
  // As wide as the longest line wants, never wider than the sky allows.
  var natural = [
    if (showEcho) _textWidth(c.echo!, body, scaler),
    for (final t in c.paragraphs) _textWidth(t, reply, scaler),
    for (final n in c.notes) _textWidth(n, note, scaler),
    // Folded or open, the same width: a tap does not resize the glass sideways.
    if (c.trace.isNotEmpty)
      _textWidth(councilTraceTitle, TypeScale.label(_anyColour), scaler) +
          ExchangeMetrics.traceGlyphGap +
          ExchangeMetrics.traceGlyph,
    for (final l in c.trace) _textWidth(l, note, scaler),
  ].fold(0.0, math.max).ceilToDouble() + 1 + inset.horizontal;
  if (c.offerId != null) {
    // The action row sits in the text column, inside the same inset.
    natural = math.max(
        natural, math.max(ExchangeMetrics.minOfferWidth, offerWidth(c.offerLabels, scaler) + inset.horizontal));
  }
  final width = math.min(natural, maxWidth);
  final inner = width - inset.horizontal;
  var h = inset.vertical;
  if (showEcho) {
    h += _textHeight(c.echo!, body, inner, scaler);
    if (c.paragraphs.isNotEmpty || c.hasNotes) h += ExchangeMetrics.echoGap;
  }
  for (final (i, t) in c.paragraphs.indexed) {
    if (i > 0) h += ExchangeMetrics.paragraphGap;
    h += _textHeight(t, reply, inner, scaler);
  }
  if (c.hasNotes) {
    if (showEcho || c.paragraphs.isNotEmpty) h += 2 * ExchangeMetrics.notesGap + hair;
    for (final (i, n) in c.notes.indexed) {
      if (i > 0) h += ExchangeMetrics.noteGap;
      h += _textHeight(n, note, inner, scaler);
    }
    if (c.trace.isNotEmpty) {
      if (c.notes.isNotEmpty) h += ExchangeMetrics.noteGap;
      h += traceToggleHeight(inner, scaler);
      if (traceOpen) {
        for (final (i, l) in c.trace.indexed) {
          if (i > 0) h += ExchangeMetrics.noteGap;
          h += _textHeight(l, note, inner, scaler);
        }
      }
    }
  }
  if (c.offerId != null) h += offerHeight(scaler, labels: c.offerLabels, width: inner);
  return ExchangeFit(size: size, echo: showEcho, inset: inset, width: width, height: h);
}

/// The first rung of the ladder at which [c] fits [height]; the last rung
/// (the scale-down guard then applies) when none does.
ExchangeFit fitExchange(ExchangeContent c,
    {required double maxWidth,
    required double height,
    required TextScaler scaler,
    double cap = 22,
    double hair = 1,
    bool traceOpen = true}) {
  ExchangeFit at(double size, bool echo, EdgeInsets inset) => measureExchange(c,
      size: size, echo: echo, inset: inset, maxWidth: maxWidth, scaler: scaler, hair: hair, traceOpen: traceOpen);
  late ExchangeFit last;
  for (final (size, _) in TypeScale.replySteps.where((s) => s.$1 <= cap)) {
    last = at(size, true, ExchangeMetrics.inset);
    if (last.height <= height) return last;
  }
  final floor = math.min(cap, TypeScale.replyFloor);
  for (final (echo, inset) in [(false, ExchangeMetrics.inset), (false, ExchangeMetrics.tightInset)]) {
    last = at(floor, echo, inset);
    if (last.height <= height) return last;
  }
  return last;
}

class GlassExchange extends StatelessWidget {
  const GlassExchange({
    super.key,
    required this.entries,
    required this.onChoice,
    this.memory,
    this.exchange,
    this.grow = Motion.enter,
    this.traceOpen = true,
    this.onTraceToggle,
  });

  final List<ChatEntry> entries;

  /// The trace toggle ("How the council answered").
  static const traceToggleKey = ValueKey('council-trace-toggle');

  /// Whether the council trace shows its lines; [onTraceToggle] gets a tap
  /// on its title.
  final bool traceOpen;
  final VoidCallback? onTraceToggle;

  /// A tapped Yes or No.
  final void Function(String label) onChoice;

  /// Remembers the reply size across rebuilds of one [exchange].
  final FitMemory? memory;
  final Object? exchange;

  /// How long the glass takes to grow to new text; zero with reduced motion.
  final Duration grow;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final hair = 1 / (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
    final content = ExchangeContent.of(entries);
    return LayoutBuilder(builder: (context, box) {
      final cap = memory?.capFor(exchange ?? entries.length) ?? TypeScale.replySteps.first.$1;
      final fit = fitExchange(content,
          maxWidth: math.min(box.maxWidth, ExchangeMetrics.maxWidth),
          height: box.maxHeight,
          scaler: scaler,
          cap: cap,
          hair: hair,
          traceOpen: traceOpen);
      memory?.cap = fit.size;
      return Align(
        alignment: ExchangeMetrics.place,
        // The guard: scales down only if even the last rung is too tall.
        child: FittedBox(fit: BoxFit.scaleDown, child: _glass(context, content, fit, hair)),
      );
    });
  }

  Widget _glass(BuildContext context, ExchangeContent c, ExchangeFit fit, double hair) {
    final p = SkyLight.paletteOf(context);
    final offer = c.offerId;
    Widget sized(Widget child) => grow == Duration.zero
        ? child
        : AnimatedSize(duration: grow, curve: Motion.enterCurve, alignment: Alignment.topCenter, child: child);
    return GlassPanel(
      child: sized(
        SizedBox(
          width: fit.width,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: fit.inset,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (fit.echo) ...[
                  Text(c.echo!, style: TypeScale.body(p.ink2)),
                  if (c.paragraphs.isNotEmpty || c.hasNotes) const SizedBox(height: ExchangeMetrics.echoGap),
                ],
                if (c.paragraphs.isNotEmpty)
                  Semantics(
                    liveRegion: true,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final (i, t) in c.paragraphs.indexed) ...[
                        if (i > 0) const SizedBox(height: ExchangeMetrics.paragraphGap),
                        Text(t, style: TypeScale.reply(p.ink, size: fit.size)),
                      ],
                    ]),
                  ),
                if (c.hasNotes) ...[
                  if (fit.echo || c.paragraphs.isNotEmpty) ...[
                    const SizedBox(height: ExchangeMetrics.notesGap),
                    Container(key: const ValueKey('exchange-notes-rule'), height: hair, color: p.rimSide),
                    const SizedBox(height: ExchangeMetrics.notesGap),
                  ],
                  for (final (i, n) in c.notes.indexed) ...[
                    if (i > 0) const SizedBox(height: ExchangeMetrics.noteGap),
                    Text(n, style: TypeScale.note(p.ink2)),
                  ],
                  if (c.trace.isNotEmpty) ...[
                    if (c.notes.isNotEmpty) const SizedBox(height: ExchangeMetrics.noteGap),
                    _TraceToggle(open: traceOpen, onTap: onTraceToggle, palette: p),
                    if (traceOpen)
                      for (final (i, l) in c.trace.indexed) ...[
                        if (i > 0) const SizedBox(height: ExchangeMetrics.noteGap),
                        Text(l, key: ValueKey('council-trace-line-$i'), style: TypeScale.note(p.ink2)),
                      ],
                  ],
                ],
              ]),
            ),
            if (offer != null)
              Padding(
                // In the text column: its rule and cells share the reply's edges.
                padding: EdgeInsets.only(left: fit.inset.left, right: fit.inset.right),
                child: GlassActions(topRule: true, actions: [
                if (c.offerChoices case final choices?)
                  for (final (i, label) in choices.indexed)
                    GlassAction(label, () => onChoice(label),
                        key: ValueKey('offer-$offer-$i'), primary: i == choices.length - 1)
                else ...[
                  GlassAction('Yes', () => onChoice('Yes'), key: ValueKey('offer-$offer-yes'), primary: true),
                  GlassAction('No', () => onChoice('No'), key: ValueKey('offer-$offer-no')),
                ],
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// "How the council answered" with a chevron: a 48 px target that folds and
/// opens the trace lines. Built inside the panel, so it takes the halo.
class _TraceToggle extends StatelessWidget {
  const _TraceToggle({required this.open, required this.onTap, required this.palette});
  final bool open;
  final VoidCallback? onTap;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    // Material below resets DefaultTextStyle, so the halo is passed here.
    final style = TypeScale.label(palette.ink2).copyWith(shadows: TextHalo.of(context));
    return Semantics(
      button: true,
      expanded: open,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: GlassExchange.traceToggleKey,
          onTap: onTap,
          highlightColor: palette.ink.withValues(alpha: 0.08),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Space.target),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s12),
              child: Row(children: [
                Flexible(child: Text(councilTraceTitle, style: style)),
                const SizedBox(width: ExchangeMetrics.traceGlyphGap),
                // Points right when folded, down when open.
                RotatedBox(
                  quarterTurns: open ? 1 : 0,
                  child: IllunisIcon(IllunisGlyph.forward, color: palette.ink2, size: ExchangeMetrics.traceGlyph),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
