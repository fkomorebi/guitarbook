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
