import 'dart:typed_data';

/// Fixed PCM16 storage. Writing never grows storage or retains old blocks.
class RecordingBuffer {
  RecordingBuffer(int capacityBytes)
    : _samples = Int16List(capacityBytes ~/ 2) {
    if (_samples.isEmpty) throw ArgumentError.value(capacityBytes);
  }

  final Int16List _samples;
  int _write = 0;
  int length = 0;
  int totalFrames = 0;
  int get capacityBytes => _samples.length * 2;

  void add(double sample) {
    _samples[_write] = (sample.clamp(-1, 1) * 32767).round();
    _write = (_write + 1) % _samples.length;
    if (length < _samples.length) length++;
    totalFrames++;
  }

  int sampleAt(int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    return _samples[(_write - length + index) % _samples.length];
  }

  Uint8List toWav() {
    final data = ByteData(44 + length * 2);
    void tag(int offset, String tag) {
      for (var i = 0; i < tag.length; i++) {
        data.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + length * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 48000, Endian.little);
    data.setUint32(28, 96000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, length * 2, Endian.little);
    for (var i = 0; i < length; i++) {
      data.setInt16(44 + i * 2, sampleAt(i), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
