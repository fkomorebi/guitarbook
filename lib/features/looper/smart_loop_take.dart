import 'dart:math' as math;
import 'dart:typed_data';

import 'loop_samples.dart';

/// Energy-based boundary detection, not instrument/source separation.
/// All decisions use sample windows, independent of input stream chunk sizes.
class SmartLoopTake {
  SmartLoopTake({required double thresholdDb})
    : _minimum = math.pow(10, thresholdDb / 20).toDouble();

  final double _minimum;
  final take = LoopTake(maxLoopFrames);
  final _preRoll = Float32List(loopSampleRate * 110 ~/ 1000);
  final List<double> _noise = [];
  int? _low;
  int _received = 0;
  int _ringPosition = 0;
  int _windowFrames = 0;
  double _energy = 0;
  double _threshold = 1;
  double _noiseFloor = 0;
  int _attackWindows = 0;
  int _releaseWindows = 0;
  int _lastSound = 0;
  bool started = false;
  bool done = false;
  bool timedOut = false;

  bool get calibrating => _received < loopSampleRate ~/ 2;
  double get seconds => take.count / loopSampleRate;
  int get trimmedFrames =>
      math.min(take.count, _lastSound + loopSampleRate ~/ 10);

  void add(Uint8List bytes) {
    for (final byte in bytes) {
      if (done) return;
      if (_low == null) {
        _low = byte;
        continue;
      }
      final raw = _low! | (byte << 8);
      _low = null;
      final sample = (raw >= 32768 ? raw - 65536 : raw) / 32768;
      _preRoll[_ringPosition] = sample;
      _ringPosition = (_ringPosition + 1) % _preRoll.length;
      if (started) take.addSample(sample);
      _received++;
      _energy += sample * sample;
      _windowFrames++;
      if (_windowFrames == loopSampleRate ~/ 100) {
        _window(math.sqrt(_energy / _windowFrames));
        _windowFrames = 0;
        _energy = 0;
      }
      if (started && take.count == take.limit) done = true;
      if (!started && _received >= loopSampleRate * 30) {
        timedOut = true;
        done = true;
      }
    }
  }

  void _window(double rms) {
    if (_received <= loopSampleRate ~/ 2) {
      _noise.add(rms);
      if (!calibrating) {
        _noise.sort();
        // Median calibration rejects isolated handling clicks.
        _noiseFloor = _noise[_noise.length ~/ 2];
        _threshold = math.max(_minimum, _noiseFloor * 4);
      }
      return;
    }
    if (!started) {
      _attackWindows = rms >= _threshold ? _attackWindows + 1 : 0;
      if (_attackWindows < 8) return;
      started = true;
      // 80 ms confirmation plus 30 ms before the onset.
      for (var i = 0; i < _preRoll.length; i++) {
        take.addSample(_preRoll[(_ringPosition + i) % _preRoll.length]);
      }
      _lastSound = take.count;
      return;
    }
    // Hysteresis keeps decaying notes below the onset threshold.
    final release = math.max(_threshold / 4, _noiseFloor * 2);
    _releaseWindows = rms >= release ? _releaseWindows + 1 : 0;
    if (_releaseWindows >= 4) _lastSound = take.count;
    if (take.count - _lastSound >= loopSampleRate * 2) done = true;
  }
}
