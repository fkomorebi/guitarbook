import 'pitch_detector.dart';
import 'tuning_reference.dart';

/// Recognizes nearby standard open strings without folding octaves.
class AutomaticStringSelector {
  int? _candidate;
  int? _since;
  int? _lastSample;
  TuningReference _reference = TuningReference.standard;

  /// 当前使用的基准音；目标频率随基准缩放。
  TuningReference get reference => _reference;

  /// 切换基准音时清空确认状态，避免旧基准下已确认的弦沿用到新基准。
  set reference(TuningReference value) {
    if (_reference == value) return;
    _reference = value;
    reset();
  }

  int? update(double? frequency, int nowMs) {
    int? nearest;
    var distance = 180.0;
    if (frequency != null && frequency.isFinite && frequency > 0) {
      for (var i = 0; i < guitarStrings.length; i++) {
        final cents = centsBetween(
          frequency,
          _reference.stringFrequency(i),
        ).abs();
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
