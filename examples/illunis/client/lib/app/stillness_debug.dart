import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Debug builds only: a three-finger long press opens a slider for the
/// water's stillness (0 mirror calm .. 1 rough). In profile and release
/// builds this returns [child] unchanged, so no control exists there and the
/// slider code is tree-shaken (kDebugMode is a compile-time constant).
class StillnessDebugGate extends StatelessWidget {
  const StillnessDebugGate({super.key, required this.value, required this.child});

  final ValueNotifier<double> value;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      kDebugMode ? _StillnessDebug(value: value, child: child) : child;
}

class _StillnessDebug extends StatefulWidget {
  const _StillnessDebug({required this.value, required this.child});
  final ValueNotifier<double> value;
  final Widget child;

  @override
  State<_StillnessDebug> createState() => _StillnessDebugState();
}

class _StillnessDebugState extends State<_StillnessDebug> {
  static const hold = Duration(milliseconds: 700);
  final _down = <int>{};
  Timer? _timer;
  bool _open = false;

  void _onDown(PointerDownEvent e) {
    _down.add(e.pointer);
    if (_down.length == 3) {
      _timer?.cancel();
      _timer = Timer(hold, () {
        if (mounted) setState(() => _open = !_open);
      });
    }
  }

  void _onUp(PointerEvent e) {
    _down.remove(e.pointer);
    if (_down.length < 3) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: Stack(fit: StackFit.expand, children: [
        widget.child,
        if (_open)
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Material(
              key: const ValueKey('stillness-debug'),
              color: const Color(0xCC000000),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                child: ValueListenableBuilder<double>(
                  valueListenable: widget.value,
                  builder: (context, v, _) => Row(children: [
                    Text('stillness ${v.toStringAsFixed(2)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    Expanded(
                      child: Slider(value: v, onChanged: (x) => widget.value.value = x),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => setState(() => _open = false),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
