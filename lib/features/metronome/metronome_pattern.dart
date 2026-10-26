import 'dart:math' as math;
import 'dart:typed_data';

/// One complete bar. Its duration is exactly beats * 60 / bpm seconds.
class MetronomePattern {
  MetronomePattern({
    required this.bpm,
    required this.beats,
    required this.accent,
  }) {
    if (bpm < 30 || bpm > 240 || beats < 1 || beats > 12) {
      throw ArgumentError('Unsupported tempo or beats per bar');
    }
    // A nearby multiple of BPM makes every beat an integer number of frames.
    // The output engine resamples this source to the device sample rate.
    sampleRate = (48000 / bpm).round() * bpm;
    framesPerBeat = sampleRate * 60 ~/ bpm;
    samples = Float32List(framesPerBeat * beats);
    final normal = _click(1000, 0.55);
    final strong = _click(1600, 0.8);
    for (var beat = 0; beat < beats; beat++) {
      samples.setRange(
        beat * framesPerBeat,
        beat * framesPerBeat + normal.length,
        accent && beat == 0 ? strong : normal,
      );
    }
  }

  final int bpm;
  final int beats;
  final bool accent;
  late final int sampleRate;
  late final int framesPerBeat;
  late final Float32List samples;

  Float32List _click(double frequency, double volume) {
    final length = (sampleRate * 0.025).round();
    return Float32List.fromList(
      List.generate(length, (i) {
        final t = i / sampleRate;
        final attack = math.min(1.0, t / 0.001);
        final release = math.max(0.0, 1 - i / (length - 1));
        return volume *
            attack *
            release *
            release *
            math.sin(2 * math.pi * frequency * t);
      }),
    );
  }

  /// Uncompressed mono PCM16 WAV, including the silence between clicks.
  Uint8List toWav() {
    final bytes = ByteData(44 + samples.length * 2);
    void tag(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    bytes.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      bytes.setInt16(44 + i * 2, (samples[i] * 32767).round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
