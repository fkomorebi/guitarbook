import 'dart:math' as math;

import 'pitch_detector.dart';

/// Presentation state; timestamps are monotonic milliseconds.
class TuningFeedback {
  double? cents;
  bool inTune = false;
  bool stale = false;
  int? _lastReading;
  int? _steadySince;

  void reset() {
    stale = false;
    cents = null;
    inTune = false;
    _lastReading = null;
    _steadySince = null;
  }

  void expire(int now) {
    if (_lastReading == null) return;
    if (now - _lastReading! >= 3000) {
      reset();
    } else if (now - _lastReading! >= 450) {
      stale = true;
      inTune = false;
      _steadySince = null;
    }
  }

  void update(double? frequency, double target, int now) {
    expire(now);
    if (frequency == null) {
      _steadySince = null;
      return;
    }
    final wasStale = stale;
    stale = false;
    final raw = centsBetween(frequency, target);
    final previous = _lastReading;
    final alpha = previous == null || wasStale
        ? 1.0
        : 1 - math.exp(-(now - previous) / 160);
    cents = cents == null ? raw : cents! + alpha * (raw - cents!);
    _lastReading = now;
    if (raw.abs() > 7 || cents!.abs() > 7) inTune = false;
    if (raw.abs() <= 5 && cents!.abs() <= 5) {
      _steadySince ??= now;
      if (now - _steadySince! >= 600) inTune = true;
    } else {
      _steadySince = null;
    }
  }

  void interruptConfirmation() {
    inTune = false;
    _steadySince = null;
  }

  double? frequency(double target) =>
      cents == null ? null : target * math.pow(2, cents! / 1200);
}
