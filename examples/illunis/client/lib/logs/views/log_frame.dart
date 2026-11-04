/// Shared layout for the log views: one clear glass sheet over the sky
/// (GlassSheet) with the title and Close at the top right, the day between
/// two thin chevrons, the day's rows, one figure row for the total, and
/// the typed capture with Save? Yes / No. Inks follow the sky (SkyLight):
/// pale at night, dark by day, and the sheet's tint is solved so every
/// text reads at 4.5:1 or more over the sky behind it. 16 px gutters;
/// nothing scrolls sideways; motion follows MediaQuery.disableAnimations.
library;

import 'package:flutter/material.dart';

import '../../app/server_port.dart';
import '../../health/daily_signals.dart';
import '../../ui/icons.dart';
import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';
import '../../widgets/glass/glass_actions.dart';
import '../../widgets/glass/glass_field.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../log_capture.dart';
import '../log_entry.dart';
import '../log_math.dart' show numText;
import '../log_store.dart';

/// What the log views need. Built once by the app.
class LogViews {
  LogViews({
    required this.store,
    required this.server,
    this.signals,
    this.effort = 'none',
    DateTime Function()? clock,
    this.log,
  }) : clock = clock ?? DateTime.now;

  final LogStore store;
  final ServerPort server;

  /// Device daily signals (Health Connect) for the wellbeing view; null or
  /// a failure shows its empty state. No model is involved.
  final Future<List<DailySignals>> Function()? signals;

  /// Standing strength effort pref: `none`, `rir` or `rpe`.
  final String effort;
  final DateTime Function() clock;
  final void Function(String line)? log;
}

/// Row text: Jost body in ink, with tabular figures so numbers in rows
/// stacked under each other line up digit by digit.
TextStyle logBody(Palette p) => TypeScale.body(p.ink, tabular: true);

/// A row's name or a heading: body type, a touch heavier.
TextStyle logStrong(Palette p) =>
    logBody(p).copyWith(fontVariations: const [FontVariation('wght', 520)], fontWeight: FontWeight.w500);

/// Space above every heading (a meal, an exercise, a run, a log kind), so
/// sections start the same way in every view.
const logHeadingPadding = EdgeInsets.only(top: Space.s12, bottom: Space.s4);

/// One device pixel, the width of every rule.
double hairline(BuildContext context) => 1 / (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// `Wednesday 28 October`.
String dayLabel(DateTime d) => '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

/// `28 Oct`.
String shortDayLabel(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)}';

abstract final class LogKeys {
  static const close = ValueKey('log-close');
  static const prevDay = ValueKey('log-prev-day');
  static const nextDay = ValueKey('log-next-day');
  static const field = ValueKey('log-field');
  static const send = ValueKey('log-send');
  static const saveYes = ValueKey('log-save-yes');
  static const saveNo = ValueKey('log-save-no');
  static const total = ValueKey('log-total');
  static const previewTotal = ValueKey('log-preview-total');
  static const empty = ValueKey('log-empty');
  static const checked = ValueKey('log-checked');
  static const choiceDiscard = ValueKey('log-choice-discard');
  static ValueKey<String> keepMine(int item) => ValueKey('log-choice-keep-$item');
  static ValueKey<String> useFound(int item) => ValueKey('log-choice-use-$item');
}

/// The sheet, header and day row around a view's body.
class LogScaffold extends StatelessWidget {
  const LogScaffold({
    super.key,
    required this.title,
    required this.day,
    required this.onClose,
    required this.body,
    this.onPrevDay,
    this.onNextDay,
    this.footer,
  });

  final String title;
  final String day;
  final VoidCallback onClose;
  final VoidCallback? onPrevDay, onNextDay;
  final Widget body;
  final Widget? footer;

  /// The most of the height above the keyboard the footer may take.
  static const footerShare = 0.6;

  /// The most the header's text grows with the system text size: the same
  /// clamp as the breathwork view, so Close is the same word in the same
  /// place in every view.
  static const double titleMaxScale = 1.6;

  /// The widest the rows grow on a large screen; the header stays at the
  /// sheet's full width so Close keeps the top right corner.
  static const double maxBodyWidth = 640;

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    final days = onPrevDay != null || onNextDay != null;
    // Below the header everything keeps the 16 px gutter on the right too
    // (the sheet leaves 8 px there so Close's word sits on the gutter).
    Widget gutter(Widget child) => Padding(padding: const EdgeInsets.only(right: Space.s8), child: child);
    return GlassSheet(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: titleMaxScale,
          child: SheetHeader(title: title, onClose: onClose, closeKey: LogKeys.close),
        ),
        Expanded(
          child: Padding(
            // The keyboard pushes the capture field up instead of covering it.
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxBodyWidth),
                child: LayoutBuilder(
                  builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // One height whether or not the day has chevrons, so the
                    // rows start at the same place in every view.
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: Space.target),
                      child: Row(children: [
                        Expanded(child: Text(day, style: TypeScale.label(p.ink2))),
                        if (onPrevDay != null)
                          GlassGlyphAction(IllunisGlyph.back, onPrevDay!, key: LogKeys.prevDay, label: 'Previous day'),
                        if (onNextDay != null)
                          GlassGlyphAction(IllunisGlyph.forward, onNextDay!, key: LogKeys.nextDay, label: 'Next day')
                        else if (days)
                          // Today: the back chevron keeps its place.
                          const SizedBox(width: Space.target),
                      ]),
                    ),
                    gutter(Container(height: hairline(context), color: p.rule)),
                    const SizedBox(height: Space.s8),
                    Expanded(child: gutter(body)),
                    // The capture takes at most this share of the height above
                    // the keyboard; its preview scrolls inside it.
                    if (footer != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: box.maxHeight * footerShare),
                        child: gutter(footer!),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A heading in the day's list (a meal). A heading with a figure beside it
/// (an exercise and its volume, a run, a log kind) is a strong [LogRow];
/// both take the same type and [logHeadingPadding].
class LogHeading extends StatelessWidget {
  const LogHeading(this.text, {super.key, this.padding = logHeadingPadding});
  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: padding, child: Text(text, style: logStrong(SkyLight.paletteOf(context))));
}

/// One line of row text.
class LogLine extends StatelessWidget {
  const LogLine(this.text, {super.key, this.align = TextAlign.start, this.padding = EdgeInsets.zero});
  final String text;
  final TextAlign align;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: padding, child: Text(text, textAlign: align, style: logBody(SkyLight.paletteOf(context))));
}

/// The one total under the rows, as a figure row: each number in the
/// reply serif with tabular figures, the words between in small ink2. The
/// plain text is the total line as written.
class LogTotal extends StatelessWidget {
  const LogTotal(this.text, {super.key, this.rowKey = LogKeys.total});
  final String text;

  /// The day's total, or [LogKeys.previewTotal] under an unsaved preview.
  final Key rowKey;

  /// A number standing on its own (`1,389.5`, `1:45:30`), not part of a
  /// word such as `7-day`.
  static final figure = RegExp(r'(?<![\w-])\d[\d,.:]*\d(?![\w-])|(?<![\w-])\d(?![\w-])');

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    final number = TypeScale.reply(p.ink)
        .copyWith(fontFeatures: const [FontFeature.liningFigures(), FontFeature.tabularFigures()]);
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in figure.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(TextSpan(text: m.group(0), style: number));
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Container(
      key: rowKey,
      margin: const EdgeInsets.only(top: Space.s8),
      padding: const EdgeInsets.only(top: Space.s8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.rule, width: hairline(context)))),
      child: Text.rich(TextSpan(children: spans), style: TypeScale.note(p.ink2)),
    );
  }
}

/// What to do when nothing is there, in one short line; never a blank
/// view.
class LogEmpty extends StatelessWidget {
  const LogEmpty(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        key: LogKeys.empty,
        padding: const EdgeInsets.symmetric(vertical: Space.gutter),
        child: Text(text, style: logBody(SkyLight.paletteOf(context))),
      );
}

/// Width of the widest word of [text] in [style], so a column can tell
/// whether a word would have to break.
double widestWord(String text, TextStyle style, TextScaler scaler) {
  var widest = 0.0;
  for (final w in text.split(RegExp(r'\s+'))) {
    if (w.isEmpty) continue;
    final p = TextPainter(text: TextSpan(text: w, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
      ..layout();
    if (p.width > widest) widest = p.width;
    p.dispose();
  }
  return widest.ceilToDouble();
}

/// A label and value on one line that wraps instead of overflowing. The
/// value ends at the right edge in tabular figures, so the numbers of rows
/// under each other line up. When a word would have to break (large text
/// sizes), the value goes under the label instead. A [strong] row is a
/// heading with its figure and takes [logHeadingPadding].
class LogRow extends StatelessWidget {
  const LogRow(this.label, this.value, {super.key, this.strong = false});
  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final p = SkyLight.paletteOf(context);
        final labelStyle = strong ? logStrong(p) : logBody(p);
        final valueStyle = logBody(p);
        final scaler = MediaQuery.textScalerOf(context);
        final share = (box.maxWidth - Space.s8) / 7;
        final side = widestWord(label, labelStyle, scaler) <= share * 3 && widestWord(value, valueStyle, scaler) <= share * 4;
        return Padding(
          padding: strong ? logHeadingPadding : const EdgeInsets.symmetric(vertical: Space.s4),
          child: side
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: Text(label, style: labelStyle)),
                  const SizedBox(width: Space.s8),
                  Expanded(flex: 4, child: Text(value, style: valueStyle, textAlign: TextAlign.end)),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(label, style: labelStyle),
                  if (value.isNotEmpty) Text(value, style: valueStyle),
                ]),
        );
      });
}

/// A table of short values (times, counts) that never breaks a value over
/// two lines: when the columns do not fit the width at the current text
/// size, each row shows as a [LogRow] (its [stacked] label and value)
/// instead. Header in label type, cells in body type, all with tabular
/// figures; the first column starts, the others end-align.
class LogTable extends StatelessWidget {
  const LogTable({super.key, required this.header, required this.rows, required this.stacked});
  final List<String> header;
  final List<List<String>> rows;
  final (String, String) Function(List<String> row) stacked;

  static const _pad = 2.0;

  static TextStyle headerStyle(Palette p) => TypeScale.label(p.ink2);
  static TextStyle cellStyle(Palette p) => TypeScale.body(p.ink, tabular: true);

  Widget _cell(String t, int col, TextStyle style) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: _pad),
        child: Text(t, style: style, textAlign: col == 0 ? TextAlign.start : TextAlign.end),
      );

  /// The widest cell of each column, padding included.
  List<double> _widths(TextScaler scaler, Palette p) {
    double measure(String t, TextStyle style) {
      final tp = TextPainter(text: TextSpan(text: t, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
        ..layout();
      final w = tp.width;
      tp.dispose();
      return w.ceilToDouble() + 2 * _pad;
    }

    return [
      for (var c = 0; c < header.length; c++)
        [
          measure(header[c], headerStyle(p)),
          for (final r in rows) measure(r[c], cellStyle(p)),
        ].reduce((a, b) => a > b ? a : b),
    ];
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final p = SkyLight.paletteOf(context);
        final widths = _widths(MediaQuery.textScalerOf(context), p);
        if (widths.fold(0.0, (a, b) => a + b) > box.maxWidth) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (label, value) in rows.map(stacked)) LogRow(label, value),
          ]);
        }
        return Table(
          columnWidths: {for (var c = 0; c < header.length; c++) c: IntrinsicColumnWidth(flex: c == 0 ? 0.6 : 1)},
          defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            TableRow(children: [for (final (c, h) in header.indexed) _cell(h, c, headerStyle(p))]),
            for (final r in rows) TableRow(children: [for (final (c, v) in r.indexed) _cell(v, c, cellStyle(p))]),
          ],
        );
      });
}

/// One log kind's view: the day's entries from [LogStore], the total, and
/// the typed capture. [rows] draws entries (also used for the preview).
class LogDayView extends StatefulWidget {
  const LogDayView({
    super.key,
    required this.kind,
    required this.title,
    required this.deps,
    required this.onClose,
    required this.rows,
    required this.total,
    required this.emptyText,
  });

  final LogKind kind;
  final String title;
  final LogViews deps;
  final VoidCallback onClose;
  final List<Widget> Function(List<LogEntry> entries) rows;
  final String Function(List<LogEntry> entries) total;
  final String emptyText;

  @override
  State<LogDayView> createState() => _LogDayViewState();
}

class _LogDayViewState extends State<LogDayView> {
  late DateTime _day;
  late final LogCapture _capture;
  List<LogEntry>? _entries;
  final _text = TextEditingController();

  String get _key => dayKey(_day);

  @override
  void initState() {
    super.initState();
    final now = widget.deps.clock();
    _day = DateTime(now.year, now.month, now.day);
    _capture = LogCapture(
      kind: widget.kind,
      server: widget.deps.server,
      store: widget.deps.store,
      date: () => _key,
      effort: widget.deps.effort,
      log: widget.deps.log,
    );
    widget.deps.store.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.deps.store.removeListener(_reload);
    _capture.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final key = _key;
    final list = await widget.deps.store.forDay(widget.kind, key);
    if (!mounted || key != _key) return;
    setState(() => _entries = list);
  }

  void _shift(int days) {
    setState(() {
      _day = DateTime(_day.year, _day.month, _day.day + days);
      _entries = null;
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final now = widget.deps.clock();
    final isToday = dayKey(now) == _key;
    return LogScaffold(
      title: widget.title,
      day: isToday ? 'Today, ${dayLabel(_day)}' : dayLabel(_day),
      onClose: widget.onClose,
      onPrevDay: () => _shift(-1),
      onNextDay: isToday ? null : () => _shift(1),
      body: entries == null
          ? const SizedBox.shrink()
          : ListView(padding: EdgeInsets.zero, children: [
              if (entries.isEmpty) LogEmpty(widget.emptyText) else ...widget.rows(entries),
              if (entries.isNotEmpty) LogTotal(widget.total(entries)),
            ]),
      footer: _captureArea(),
    );
  }

  Widget _captureArea() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return ListenableBuilder(
      listenable: _capture,
      builder: (context, _) {
        final p = SkyLight.paletteOf(context);
        final s = _capture.state;
        final screenH = MediaQuery.sizeOf(context).height;
        // Rows scroll in whatever height is left; the question and its
        // actions stay pinned below them.
        Widget rows(double share, List<Widget> children) => Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: screenH * share),
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
            );
        Widget line(Widget text) => SingleChildScrollView(child: text);
        final Widget status = switch (s) {
          CaptureIdle() => const SizedBox.shrink(),
          CaptureReading() => line(Text(CaptureText.reading, style: TypeScale.body(p.ink2))),
          CaptureMessage(:final text) => line(Text(text, style: logBody(p))),
          CaptureCrisis(:final referral) =>
            line(Semantics(liveRegion: true, child: Text(referral, style: logStrong(p)))),
          CaptureChoice(:final entry, :final choices) =>
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              rows(0.4, [
                Semantics(liveRegion: true, child: Text(CaptureText.verify, style: logStrong(p))),
                for (final c in choices) _choiceRow(entry, c, p),
              ]),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: GlassTextAction('Discard', _capture.discardChoice, key: LogKeys.choiceDiscard),
              ),
            ]),
          CapturePreview(:final entry, :final checkedAgainst) =>
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Each item with its calories, then the entry's own total.
              rows(0.3, [...widget.rows([entry]), LogTotal(widget.total([entry]), rowKey: LogKeys.previewTotal)]),
              if (checkedAgainst != null)
                Text(
                  CaptureText.checkedAgainst(checkedAgainst),
                  key: LogKeys.checked,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TypeScale.note(p.ink2),
                ),
              Row(children: [
                Expanded(child: Text(CaptureText.savePrompt, style: logStrong(p))),
                Expanded(
                  child: GlassActions(actions: [
                    GlassAction('Yes', () => _capture.answer(true), key: LogKeys.saveYes, primary: true),
                    GlassAction('No', () => _capture.answer(false), key: LogKeys.saveNo),
                  ]),
                ),
              ]),
            ]),
        };
        final padded = Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: status);
        return Padding(
          padding: const EdgeInsets.only(top: Space.s8, bottom: Space.s8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Reduced motion: the status changes in place, with no size animation.
            Flexible(
              child: reduceMotion
                  ? padded
                  : AnimatedSize(
                      duration: Motion.enter,
                      curve: Motion.enterCurve,
                      alignment: Alignment.bottomCenter,
                      child: padded,
                    ),
            ),
            GlassField(
              fieldKey: LogKeys.field,
              sendKey: LogKeys.send,
              sendLabel: 'Log it',
              controller: _text,
              sendEnabled: s is! CaptureReading,
              // The example wraps at large text sizes instead of being cut off.
              hintMaxLines: 6,
              hint: CaptureText.examples[widget.kind]!,
              onSubmit: _capture.submit,
            ),
          ]),
        );
      },
    );
  }

  /// One mismatch: the user's number against the found one, with the source
  /// title and host as text. Keep mine, or use the found number.
  Widget _choiceRow(LogEntry entry, FoodChoice c, Palette p) {
    final name = entry is FoodEntry && c.itemIndex < entry.items.length ? entry.items[c.itemIndex].name : 'Item';
    final host = c.sourceUrl == null ? null : Uri.tryParse(c.sourceUrl!)?.host;
    final mine = numText(c.userValue.toDouble());
    final found = numText(c.foundValue.toDouble());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('$name: You wrote $mine kcal. ${c.sourceTitle ?? 'The source'} lists $found kcal.', style: logBody(p)),
        if (host != null && host.isNotEmpty) Text(host, style: TypeScale.note(p.ink2)),
        GlassActions(actions: [
          GlassAction('Keep mine ($mine)', () => _capture.chooseOne(c, useFound: false), key: LogKeys.keepMine(c.itemIndex)),
          GlassAction('Use $found', () => _capture.chooseOne(c, useFound: true),
              key: LogKeys.useFound(c.itemIndex), primary: true),
        ]),
      ]),
    );
  }
}
