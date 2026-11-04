/// The text chat on the main view (build plan B2), on clear glass over the
/// sky. It fills the root Stack: the latest exchange sits a little above the
/// middle of the open sky and grows to fit (no scrolling; see the fit
/// ladder in glass/glass_exchange.dart), and one glass input with a send
/// glyph stays at the bottom, above the keyboard. Sending closes the
/// keyboard so the reply gets the sky.
///
/// The reply, your line, the input text and its hint are inverse-colour
/// text ([TypeScale.inverseText]): each stroke shows the opposite of the sky
/// under it. SkyLight gives the halo (light by day, dark by night) only as
/// strong as 4.5:1 needs over the sky behind it, and the cursor and glyphs.
/// Offers ("Open your logs?") carry Yes and No that submit the same words a
/// typed answer would. Shown whatever the fog setting is.
library;

import 'package:flutter/material.dart';

import '../app/chat_thread.dart';
import '../ui/tokens.dart';
import 'glass/glass_exchange.dart';
import 'glass/glass_field.dart';
import 'glass/glass_surface.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.thread,
    required this.onSubmit,
  });

  final ChatThread thread;

  /// A typed message or a tapped Yes / No.
  final void Function(String text) onSubmit;

  static const fieldKey = ValueKey('chat-field');
  static const sendKey = ValueKey('chat-send');
  static const hint = 'Write to Illunis';

  /// Side gutter, logical px.
  static const double gutter = Space.gutter;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _fit = FitMemory();

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final fade = reduceMotion ? Duration.zero : Motion.enter;
    return Material(
      type: MaterialType.transparency,
      // The reply glass and the input blur the sky in one pass.
      child: BackdropGroup(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SafeArea(
            child: Padding(
              // A deeper bottom keeps the input clear of the nav bar.
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.gutter, Space.gutter, Space.s32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: ExchangeMetrics.maxWidth),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _exchange(fade)),
                    _input(),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _exchange(Duration fade) => ListenableBuilder(
        listenable: widget.thread,
        builder: (context, _) {
          final latest = widget.thread.latestExchange;
          // One key per exchange: a new exchange fades in, a growing reply
          // grows its glass instead.
          final start = widget.thread.entries.length - latest.length;
          return AnimatedSwitcher(
            duration: fade,
            switchInCurve: Motion.enterCurve,
            switchOutCurve: Motion.exitCurve,
            child: latest.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    key: ValueKey(start),
                    padding: const EdgeInsets.only(bottom: Space.s12),
                    child: GlassExchange(
                      entries: latest,
                      onChoice: widget.onSubmit,
                      memory: _fit,
                      exchange: start,
                      grow: fade,
                      traceOpen: widget.thread.traceOpen,
                      onTraceToggle: widget.thread.toggleTrace,
                    ),
                  ),
          );
        },
      );

  Widget _input() => GlassPanel(
        padding: const EdgeInsets.only(left: Space.inset, right: Space.s4),
        child: GlassField(
          fieldKey: ChatComposer.fieldKey,
          sendKey: ChatComposer.sendKey,
          hint: ChatComposer.hint,
          hintMaxLines: 1,
          // The sans hint one step up from body: the scale's next size, 18.
          hintType: (c) => TypeScale.body(c).copyWith(fontSize: TypeScale.replyFloor),
          baseline: false,
          unfocusOnSubmit: true,
          onSubmit: widget.onSubmit,
        ),
      );
}
