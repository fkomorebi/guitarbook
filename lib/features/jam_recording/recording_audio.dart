import '../metronome/metronome_audio.dart';
import '../metronome/metronome_pattern.dart';

/// Tracks only successfully started playback, sharing the rendered source.
class RecordingAudio implements PositionedLoopAudio {
  RecordingAudio(this.output, this.onDispose);
  final MetronomeAudio output;
  final void Function(RecordingAudio) onDispose;
  MetronomePattern? _pattern;
  bool _playing = false;
  double _gain = 1;
  double? _cursor;
  int _pendingFrames = 0;

  void _resetClock() {
    _cursor = null;
    _pendingFrames = 0;
  }

  @override
  Future<void> unlock() => output.unlock();
  @override
  Future<void> prepare(MetronomePattern pattern) async {
    await output.prepare(pattern);
    _pattern = pattern;
    _resetClock();
  }

  @override
  void play() {
    output.play();
    _playing = true;
    _resetClock();
  }

  @override
  void playAt(Duration offset) {
    (output as PositionedLoopAudio).playAt(offset);
    _playing = true;
    _resetClock();
  }

  @override
  Duration get position => output.position;
  @override
  void setGain(double gain) {
    output.setGain(gain);
    _gain = gain;
  }

  @override
  void silence() {
    _playing = false;
    _resetClock();
    output.silence();
  }

  @override
  Future<void> clear() async {
    _playing = false;
    _pattern = null;
    _resetClock();
    await output.clear();
  }

  @override
  Future<void> dispose() async {
    _playing = false;
    _pattern = null;
    _resetClock();
    onDispose(this);
    await output.dispose();
  }

  /// Snapshot the playback phase once per input block, resampling the source.
  ///
  /// The engine reports its playback position quantized to whole mix buffers
  /// (SoLoud: 512 frames ~ 10.7 ms) and the Dart callback runs at an arbitrary
  /// phase of that clock, so re-deriving the source phase from `position` on
  /// every block makes the recorded stem jump by up to one buffer at each block
  /// boundary. That tears the timeline heard in the recording. Anchor the source
  /// phase on the first block, then advance it by the frames actually recorded
  /// and apply only a slow (inaudible) correction for engine/input clock drift.
  double Function(int) block(int frames) {
    final pattern = _pattern;
    if (!_playing || pattern == null || pattern.samples.isEmpty) {
      return (_) => 0;
    }
    final ratio = pattern.sampleRate / 48000;
    final reported =
        position.inMicroseconds * pattern.sampleRate / 1000000 - frames * ratio;
    final cursor = _cursor;
    final double start;
    if (cursor == null) {
      start = reported;
    } else {
      final predicted = cursor + _pendingFrames * ratio;
      final drift = reported - predicted;
      if (drift.abs() > 4800 * ratio) {
        // Engine clock jumped (seek/restart/loop wrap): follow it immediately.
        start = reported;
      } else {
        final limit = frames * ratio * 0.002;
        start = predicted + drift.clamp(-limit, limit);
      }
    }
    _cursor = start;
    _pendingFrames = frames;
    final gain = _gain;
    return (int frame) {
      final phase = start + frame * ratio;
      final floor = phase.floor();
      final a = pattern.samples[floor % pattern.samples.length];
      final b = pattern.samples[(floor + 1) % pattern.samples.length];
      return (a + (b - a) * (phase - floor)) * gain;
    };
  }
}
