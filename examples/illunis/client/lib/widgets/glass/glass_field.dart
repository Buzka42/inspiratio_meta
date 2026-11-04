/// The one text field (chat, logs, breath): body text and its hint in
/// inverse colour ([TypeScale.inverseText]), the accent cursor, a hairline baseline in the rule colour, and an
/// optional send glyph that stays dim and inert until there is text. Enter
/// submits. It has no surface: its text sits on the sky, with the halo of
/// the [GlassPanel] it is in.
library;

import 'package:flutter/material.dart';

import '../../ui/icons.dart';
import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';
import 'glass_surface.dart';

class GlassField extends StatefulWidget {
  const GlassField({
    super.key,
    required this.hint,
    required this.onSubmit,
    this.controller,
    this.focusNode,
    this.fieldKey,
    this.sendKey,
    this.sendLabel = 'Send',
    this.showSend = true,
    this.sendEnabled = true,
    this.clearOnSubmit = true,
    this.unfocusOnSubmit = false,
    this.baseline = true,
    this.hintMaxLines = 4,
    this.hintType,
    this.textInputAction = TextInputAction.send,
  });

  final String hint;

  /// The trimmed text, never empty.
  final ValueChanged<String> onSubmit;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Keys for the text field and the send control (tests and audits).
  final Key? fieldKey, sendKey;
  final String sendLabel;
  final bool showSend;

  /// False keeps send inert even with text (a request in flight).
  final bool sendEnabled;
  final bool clearOnSubmit;

  /// Closes the keyboard on submit, so a reply gets the sky (UI_PLAN Q2).
  final bool unfocusOnSubmit;
  final bool baseline;
  final int hintMaxLines;

  /// The hint's step of [TypeScale] for an ink; [TypeScale.body] when null.
  final TextStyle Function(Color ink)? hintType;
  final TextInputAction textInputAction;

  /// The send glyph's opacity while it cannot send.
  static const double idleAlpha = 0.4;

  @override
  State<GlassField> createState() => _GlassFieldState();
}

class _GlassFieldState extends State<GlassField> {
  TextEditingController? _own;
  TextEditingController get _text => widget.controller ?? (_own ??= TextEditingController());
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  @override
  void didUpdateWidget(GlassField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _own)?.removeListener(_changed);
      _text.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _text.removeListener(_changed);
    _own?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _canSend => widget.sendEnabled && _text.text.trim().isNotEmpty;

  void _submit() {
    final t = _text.text.trim();
    if (t.isEmpty || !widget.sendEnabled) return;
    if (widget.clearOnSubmit) _text.clear();
    if (widget.unfocusOnSubmit) _focus.unfocus();
    widget.onSubmit(t);
  }

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    // A field does not read DefaultTextStyle: it takes the halo directly.
    final halo = TextHalo.of(context);
    final field = TextField(
      key: widget.fieldKey,
      controller: _text,
      focusNode: _focus,
      style: TypeScale.body(p.ink).copyWith(shadows: halo),
      cursorColor: p.accent,
      cursorWidth: 1.5,
      minLines: 1,
      maxLines: 4,
      // maxLines > 1 defaults to the multiline keyboard, whose Enter is a
      // newline on Android. A text keyboard keeps the wrap and makes Enter
      // the action key, so Enter sends (phone, 2026-11-04).
      keyboardType: TextInputType.text,
      textInputAction: widget.textInputAction,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintMaxLines: widget.hintMaxLines,
        hintStyle: (widget.hintType ?? TypeScale.body)(p.ink2).copyWith(shadows: halo),
        border: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: Space.s12),
      ),
    );
    final row = Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: widget.baseline
            ? DecoratedBox(
                key: const ValueKey('glass-field-baseline'),
                // A hairline: one device pixel in the rule colour (3:1 or
                // more on the glass), a line you see, not an outline.
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.rule, width: 1 / dpr))),
                child: field,
              )
            : field,
      ),
      if (widget.showSend) _send(p),
    ]);
    return row;
  }

  Widget _send(Palette p) {
    final on = _canSend;
    return Semantics(
      button: true,
      enabled: on,
      label: widget.sendLabel,
      child: AnimatedOpacity(
        opacity: on ? 1 : GlassField.idleAlpha,
        duration: Motion.press,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: widget.sendKey,
            // Always wired: an empty or blocked field just sends nothing,
            // and the glyph's dim state and Semantics say it is idle.
            onTap: _submit,
            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
            child: SizedBox.square(
              dimension: Space.target,
              child: Center(child: IllunisIcon(IllunisGlyph.send, color: p.accent)),
            ),
          ),
        ),
      ),
    );
  }
}
