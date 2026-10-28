import 'dart:math' as math;
import 'dart:typed_data';

const loopSampleRate = 48000;
const maxLoopFrames = loopSampleRate * 30;
const maxLoopLayers = 6;

/// Handles arbitrary byte boundaries in the PCM16 stream.
class LoopTake {
  LoopTake(this.limit) : _samples = Float32List(limit);
  final int limit;
  final Float32List _samples;
  int count = 0;
  int? _low;

  void addSample(double sample) {
    if (count < limit) _samples[count++] = sample;
  }

  void add(Uint8List bytes) {
    for (final byte in bytes) {
      if (count == limit) return;
      if (_low == null) {
        _low = byte;
      } else {
        final value = _low! | (byte << 8);
        _samples[count++] = (value >= 32768 ? value - 65536 : value) / 32768;
        _low = null;
      }
    }
  }

  Float32List finish({required int length, required int offset}) {
    final result = Float32List(length);
    var peak = 0.0;
    final retained = math.min(count, length);
    for (var i = 0; i < retained; i++) {
      peak = math.max(peak, _samples[i].abs());
    }
    // Preserve ordinary instrument input; attenuate only loud takes.
    // Six layers still have at most .72 combined peak, leaving drum headroom.
    final gain = peak > .12 ? .12 / peak : 1.0;
    final fade = math.min(240, retained ~/ 2);
    for (var i = 0; i < retained; i++) {
      final envelope = fade == 0
          ? 1.0
          : math.min(1.0, math.min(i, retained - 1 - i) / fade);
      result[(offset + i) % length] = _samples[i] * envelope * gain;
    }
    return result;
  }
}

int phaseFrame(Duration position, int length, int compensationMs) =>
    ((position.inMicroseconds * loopSampleRate ~/ 1000000) -
        compensationMs * loopSampleRate ~/ 1000) %
    length;

/// Measures PCM16 peaks without losing alignment across stream chunks.
class LoopInputMeter {
  int? _low;
  double peak = 0;
  int silentFrames = 0;

  void add(Uint8List bytes) {
    var blockPeak = 0.0;
    for (final byte in bytes) {
      if (_low == null) {
        _low = byte;
        continue;
      }
      final raw = _low! | (byte << 8);
      final value = (raw >= 32768 ? raw - 65536 : raw).abs() / 32768;
      _low = null;
      blockPeak = math.max(blockPeak, value);
      silentFrames = value < .000316 ? silentFrames + 1 : 0;
    }
    peak = blockPeak;
  }

  bool get quiet => silentFrames >= loopSampleRate * 3;
  double get db =>
      peak == 0 ? -96 : math.max(-96, 20 * math.log(peak) / math.ln10);
}
