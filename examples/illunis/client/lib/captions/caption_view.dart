import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../ui/sky_light.dart';
import '../ui/tokens.dart';
import 'caption_dissolve.dart';
import 'caption_style.dart';
import 'caption_timing.dart';

/// A dismissable caption that leaves as mist.
///
/// While [visible] is true the caption holds for [captionHold] of its text,
/// then exits. A tap, or [visible] turning false, starts the exit at once.
/// The exit is the shader dissolve when the program is loaded, the fog
/// setting is on and animations are allowed; otherwise a plain opacity fade
/// (short when MediaQuery.disableAnimations is set). [onDismissed] fires
/// once the caption is gone. Screen readers get the text as a live label.
///
/// With [followSky], once the sky has been looked at ([SkyLight.probe]) the
/// ink follows the sky behind the text ([CaptionInk.forLuminance]) and
/// [ink] is only the fallback before that.
///
/// IllunisRoot centres it on the sky with [CenteredCaption].
class CaptionView extends StatefulWidget {
  const CaptionView({
    super.key,
    required this.text,
    this.visible = true,
    this.fog = true,
    this.font = CaptionFont.serif,
    this.ink = CaptionInk.dark,
    this.followSky = false,
    this.fontSize = 26,
    this.fade = captionFade,
    this.onDismissed,
    this.programLoader = CaptionDissolveShader.load,
  });

  final String text;
  final bool visible;
  final bool fog;
  final CaptionFont font;
  final CaptionInk ink;
  final bool followSky;
  final double fontSize;
  final Duration fade;
  final VoidCallback? onDismissed;
  final Future<ui.FragmentProgram?> Function() programLoader;

  /// Room above the text for the upward drift, logical px.
  static const double driftMargin = 32;

  /// Padding below the text, logical px.
  static const double bottomMargin = 8;

  /// Side padding, logical px.
  static const double sideMargin = 16;

  /// Semantics hint for the tap action.
  static const String dismissHint = 'Dismiss caption';

  @override
  State<CaptionView> createState() => CaptionViewState();
}

enum _Phase { hidden, holding, exiting }

/// Public for tests: [exitMode] reports the exit the caption would use now.
class CaptionViewState extends State<CaptionView> with SingleTickerProviderStateMixin {
  late final AnimationController _exit = AnimationController(vsync: this);
  final GlobalKey _boundary = GlobalKey();
  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  ui.Image? _snapshot;
  Timer? _hold;
  _Phase _phase = _Phase.hidden;
  CaptionExit? _running;

  // The ink chosen from the sky behind the text ([CaptionView.followSky]);
  // null until the first look.
  CaptionInk? _skyInk;
  bool _looked = false;

  /// The ink in use: from the sky once looked at, else [CaptionView.ink].
  CaptionInk get ink => _skyInk ?? widget.ink;

  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  CaptionExit get exitMode => selectCaptionExit(
      shaderReady: _program != null, disableAnimations: _reduceMotion, fog: widget.fog);

  @override
  void initState() {
    super.initState();
    widget.programLoader().then((p) {
      if (mounted && p != null) setState(() => _program = p);
    }, onError: (Object _) {});
    if (widget.visible) _show();
  }

  @override
  void didUpdateWidget(CaptionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (widget.visible && (!old.visible || widget.text != old.text)) {
      _show();
    } else if (!widget.visible && old.visible) {
      dismiss();
    }
  }

  void _show() {
    _hold?.cancel();
    _exit.stop();
    _exit.value = 0;
    _clearSnapshot();
    _running = null;
    _phase = _Phase.holding;
    _hold = Timer(captionHold(widget.text), dismiss);
  }

  /// Starts the exit now (tap, hide, or the hold running out).
  void dismiss() {
    if (_phase != _Phase.holding) return;
    _hold?.cancel();
    final mode = exitMode;
    if (mode == CaptionExit.dissolve && !_capture()) {
      _running = CaptionExit.fade;
    } else {
      _running = mode;
    }
    setState(() => _phase = _Phase.exiting);
    _exit.duration = captionExitDuration(_running!, fade: widget.fade);
    _exit.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _phase != _Phase.exiting || _exit.value < 1) return;
      _clearSnapshot();
      setState(() => _phase = _Phase.hidden);
      widget.onDismissed?.call();
    });
  }

  /// Snapshots the rendered caption for the shader. False if it cannot.
  bool _capture() {
    final ro = _boundary.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize) return false;
    try {
      _snapshot = ro.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context));
      _shader ??= _program!.fragmentShader();
      return true;
    } catch (_) {
      _clearSnapshot();
      return false;
    }
  }

  void _clearSnapshot() {
    _snapshot?.dispose();
    _snapshot = null;
  }

  @override
  void dispose() {
    _hold?.cancel();
    _exit.dispose();
    _clearSnapshot();
    _shader?.dispose();
    super.dispose();
  }

  static const _margins = EdgeInsets.fromLTRB(
      CaptionView.sideMargin, CaptionView.driftMargin, CaptionView.sideMargin, CaptionView.bottomMargin);

  /// After layout: the mean sky under the text (not its margins) picks the
  /// ink. No look at the sky yet keeps the fallback.
  void _lookAtSky(SkyProbe? probe) {
    if (!mounted || _phase == _Phase.hidden) return;
    final box = _boundary.currentContext?.findRenderObject();
    if (probe == null || box is! RenderBox || !box.hasSize || !box.attached) return;
    final l = probe.meanLuminance(_margins.deflateRect(box.localToGlobal(Offset.zero) & box.size));
    final next = l == null ? _skyInk : CaptionInk.forLuminance(l, current: _skyInk);
    if (_looked && next == _skyInk) return;
    setState(() {
      _skyInk = next;
      _looked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.hidden) return const SizedBox.shrink();
    final probe = widget.followSky ? SkyLight.maybeOf(context)?.probe : null;
    if (probe != null) WidgetsBinding.instance.addPostFrameCallback((_) => _lookAtSky(probe));
    final reduce = _reduceMotion;
    Widget text = RepaintBoundary(
      key: _boundary,
      child: Padding(
        padding: _margins,
        child: _skyInk == null
            ? _text(ink.color, ink.halo)
            // A later change of ink eases, as the halo does.
            : TweenAnimationBuilder<double>(
                tween: Tween(end: _skyInk == CaptionInk.dark ? 1 : 0),
                duration: reduce ? Duration.zero : Motion.glass,
                curve: Motion.glassCurve,
                builder: (context, t, _) => _text(Color.lerp(CaptionInk.pale.color, CaptionInk.dark.color, t)!,
                    Color.lerp(CaptionInk.pale.halo, CaptionInk.dark.halo, t)!),
              ),
      ),
    );
    // The first frame, before the look, is not shown in the fallback ink.
    if (probe != null && !_looked) text = Opacity(opacity: 0, child: text);
    return Semantics(
      container: true,
      liveRegion: true,
      label: widget.text,
      onTapHint: CaptionView.dismissHint,
      onTap: dismiss,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: dismiss,
          child: _phase == _Phase.holding ? text : _exiting(text),
        ),
      ),
    );
  }

  Widget _exiting(Widget text) {
    return AnimatedBuilder(
      animation: _exit,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_exit.value);
        final img = _snapshot, shader = _shader;
        if (_running == CaptionExit.dissolve && img != null && shader != null) {
          // Keep the text's layout; paint the snapshot through the shader.
          return Stack(children: [
            Opacity(opacity: 0, child: child),
            Positioned.fill(
              child: CustomPaint(
                key: const ValueKey('caption-dissolve'),
                painter: CaptionDissolvePainter(
                    shader: shader, image: img, progress: t, seed: _seed),
              ),
            ),
          ]);
        }
        return Opacity(key: const ValueKey('caption-fade'), opacity: 1 - t, child: child);
      },
      child: text,
    );
  }

  // Straight on the sky: the caption keeps its soft halo, at full strength.
  Widget _text(Color color, Color halo) => Text(
        widget.text,
        textAlign: TextAlign.center,
        style: TypeScale.caption(color,
                sans: widget.font == CaptionFont.sans, size: widget.fontSize, wght: widget.font.weight)
            .copyWith(shadows: Halo.shadows(halo, 1)),
      );

  double get _seed => (widget.text.hashCode & 0x3ff) / 1024.0;
}

/// Places [child] (a [CaptionView]) so its text, not its drift margin, sits
/// on the centre of the area it is given. Only the caption's own box takes
/// taps; the rest of the area passes gestures through.
class CenteredCaption extends StatelessWidget {
  const CenteredCaption({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          // Balances the taller top margin so the text centre is the centre.
          padding: const EdgeInsets.only(
              bottom: CaptionView.driftMargin - CaptionView.bottomMargin),
          child: child,
        ),
      );
}
