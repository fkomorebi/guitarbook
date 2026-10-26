import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

void main() {
  test(
    'all integer tempos have exact beat/bar lengths without loop rounding',
    () {
      for (var bpm = 30; bpm <= 240; bpm++) {
        for (final beats in [1, 4, 12]) {
          final p = MetronomePattern(bpm: bpm, beats: beats, accent: true);
          expect(p.sampleRate, closeTo(48000, 120));
          expect(p.framesPerBeat * bpm, p.sampleRate * 60);
          expect(p.samples.length * bpm, p.sampleRate * 60 * beats);
          // Repeating one million bars introduces no integer-frame tempo error.
          expect(
            p.samples.length * 1000000 * bpm,
            p.sampleRate * 60 * beats * 1000000,
          );
        }
      }
    },
  );

  test(
    'clicks start at each beat, silence spans boundaries, accent is first only',
    () {
      final accented = MetronomePattern(bpm: 137, beats: 4, accent: true);
      final plain = MetronomePattern(bpm: 137, beats: 4, accent: false);
      final frames = accented.framesPerBeat;
      expect(
        accented.samples.sublist(1, 500),
        isNot(orderedEquals(plain.samples.sublist(1, 500))),
      );
      for (var beat = 0; beat < 4; beat++) {
        final start = beat * frames;
        expect(plain.samples[start], 0);
        expect(plain.samples[start + 10], isNot(0));
        expect(
          plain.samples.sublist(start + 2000, start + frames),
          everyElement(0),
        );
        if (beat > 0) {
          expect(
            accented.samples.sublist(start, start + frames),
            orderedEquals(plain.samples.sublist(0, frames)),
          );
        }
      }
      expect(accented.samples.last, 0);
    },
  );

  test('WAV carries source sample rate and exact PCM length', () {
    final p = MetronomePattern(bpm: 239, beats: 7, accent: true);
    final wav = p.toWav();
    final data = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(data.getUint32(24, Endian.little), p.sampleRate);
    expect(data.getUint32(40, Endian.little), p.samples.length * 2);
    expect(wav.length, 44 + p.samples.length * 2);
    expect(data.getInt16(64, Endian.little), (p.samples[10] * 32767).round());
  });
}
