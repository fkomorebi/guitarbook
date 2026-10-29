import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/jam_recording/recording_buffer.dart';

void main() {
  test('multiple wraps retain newest frames in chronological WAV order', () {
    final buffer = RecordingBuffer(8);
    for (var i = 1; i <= 11; i++) {
      buffer.add(i / 16);
    }
    expect(buffer.length, 4);
    expect(buffer.capacityBytes, 8);
    expect(buffer.totalFrames, 11);
    final wav = ByteData.sublistView(buffer.toWav());
    expect(wav.lengthInBytes, 52);
    expect(wav.getUint32(24, Endian.little), 48000);
    expect(wav.getUint32(40, Endian.little), 8);
    for (var i = 0; i < 4; i++) {
      expect(
        wav.getInt16(44 + i * 2, Endian.little),
        ((i + 8) / 16 * 32767).round(),
      );
    }
  });
  test('partial buffers do not export unwritten memory and clip safely', () {
    final buffer = RecordingBuffer(100);
    buffer.add(-2);
    buffer.add(2);
    expect(buffer.toWav().length, 48);
    expect(buffer.sampleAt(0), -32767);
    expect(buffer.sampleAt(1), 32767);
    expect(() => buffer.sampleAt(2), throwsRangeError);
  });
}
