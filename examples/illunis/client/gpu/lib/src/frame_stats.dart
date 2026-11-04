/// Rolling frame timing for the debug diagnostic line: the interval between
/// ticks (what the user sees as frame rate) and the time from submitting the
/// surface pass to its completion callback (GPU queue plus execution).
class FrameStats {
  FrameStats({this.window = 300});

  /// Frames per summary.
  final int window;
  final _dt = <double>[];
  final _gpu = <double>[];
  int _skipped = 0;

  void tick(double dtMs) => _dt.add(dtMs);
  void gpu(double ms) => _gpu.add(ms);
  void skipped() => _skipped++;

  /// A summary once [window] ticks are in, then the window restarts; null
  /// otherwise.
  String? take() {
    if (_dt.length < window) return null;
    String q(List<double> v, double p) {
      if (v.isEmpty) return '-';
      final s = [...v]..sort();
      return s[((s.length - 1) * p).round()].toStringAsFixed(1);
    }

    final avg = _dt.reduce((a, b) => a + b) / _dt.length;
    final out = 'frames n=${_dt.length} dt_avg_ms=${avg.toStringAsFixed(1)} '
        'dt_p50=${q(_dt, 0.5)} dt_p95=${q(_dt, 0.95)} '
        'gpu_p50_ms=${q(_gpu, 0.5)} gpu_p95_ms=${q(_gpu, 0.95)} skipped=$_skipped';
    _dt.clear();
    _gpu.clear();
    _skipped = 0;
    return out;
  }
}
