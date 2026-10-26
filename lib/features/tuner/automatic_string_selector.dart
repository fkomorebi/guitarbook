import 'pitch_detector.dart';

/// Recognizes nearby standard open strings without folding octaves.
class AutomaticStringSelector {
  int? _candidate;
  int? _since;
  int? _lastSample;

  int? update(double? frequency, int nowMs) {
    int? nearest;
    var distance = 180.0;
    if (frequency != null && frequency.isFinite && frequency > 0) {
      for (var i = 0; i < guitarStrings.length; i++) {
        final cents = centsBetween(frequency, guitarStrings[i].frequency).abs();
        if (cents <= distance) {
          distance = cents;
          nearest = i;
        }
      }
    }
    if (nearest == null) {
      reset();
      return null;
    }
    if (_candidate != nearest ||
        _lastSample == null ||
        nowMs - _lastSample! > 450 ||
        nowMs < _lastSample!) {
      _candidate = nearest;
      _since = nowMs;
    }
    _lastSample = nowMs;
    return nowMs - _since! >= 180 ? nearest : null;
  }

  void reset() {
    _candidate = null;
    _since = null;
    _lastSample = null;
  }
}
