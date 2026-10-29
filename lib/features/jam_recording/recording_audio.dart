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

  @override
  Future<void> unlock() => output.unlock();
  @override
  Future<void> prepare(MetronomePattern pattern) async {
    await output.prepare(pattern);
    _pattern = pattern;
  }

  @override
  void play() {
    output.play();
    _playing = true;
  }

  @override
  void playAt(Duration offset) {
    (output as PositionedLoopAudio).playAt(offset);
    _playing = true;
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
    output.silence();
  }

  @override
  Future<void> clear() async {
    _playing = false;
    _pattern = null;
    await output.clear();
  }

  @override
  Future<void> dispose() async {
    _playing = false;
    _pattern = null;
    onDispose(this);
    await output.dispose();
  }

  /// Snapshot the playback phase once per input block, resampling the source.
  double Function(int) block(int frames) {
    final pattern = _pattern;
    if (!_playing || pattern == null || pattern.samples.isEmpty) {
      return (_) => 0;
    }
    final start =
        position.inMicroseconds * pattern.sampleRate / 1000000 -
        frames * pattern.sampleRate / 48000;
    final gain = _gain;
    return (int frame) {
      final phase = start + frame * pattern.sampleRate / 48000;
      final floor = phase.floor();
      final a = pattern.samples[floor % pattern.samples.length];
      final b = pattern.samples[(floor + 1) % pattern.samples.length];
      return (a + (b - a) * (phase - floor)) * gain;
    };
  }
}
