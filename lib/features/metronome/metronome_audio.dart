import 'metronome_pattern.dart';

abstract interface class MetronomeAudio {
  /// Called synchronously from the user's gesture, before queued work.
  Future<void> unlock();
  Future<void> prepare(MetronomePattern pattern);
  void play();
  Duration get position;

  /// Immediately pause output, even while an older prepare is in flight.
  void silence();
  Future<void> clear();
  Future<void> dispose();
}

/// Loop playback that can join an already playing loop at its current phase.
abstract interface class PositionedLoopAudio implements MetronomeAudio {
  void playAt(Duration offset);

  /// Linear playback gain; retained across stop and play.
  void setGain(double gain);
}
