import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/tuner/pitch_detector.dart';

void main() {
  test('六根琴弦及上下偏差，带谐波时音分误差小于 2', () {
    for (final string in guitarStrings) {
      for (final cents in [-35, 0, 35]) {
        final frequency = string.frequency * pow(2, cents / 1200);
        final samples = List<double>.generate(4096, (i) {
          final phase = 2 * pi * frequency * i / 22050;
          return 0.3 * sin(phase) + 0.15 * sin(2 * phase);
        });
        final detected = detectPitch(samples);
        expect(detected, isNotNull);
        expect(centsBetween(detected!, frequency).abs(), lessThan(2));
      }
    }
  });
  test('weak sustained guitar tones remain detectable', () {
    for (final string in guitarStrings) {
      final samples = List.generate(
        4096,
        (i) => .006 * sin(2 * pi * string.frequency * i / 22050),
      );
      final pitch = detectPitch(samples);
      expect(pitch, isNotNull);
      expect(centsBetween(pitch!, string.frequency).abs(), lessThan(2));
    }
    expect(
      detectPitch(
        List.generate(4096, (i) => .001 * sin(2 * pi * 110 * i / 22050)),
      ),
      isNull,
    );
  });
  test('静音、低音量及随机噪声无读数', () {
    expect(detectPitch(List.filled(4096, 0)), isNull);
    expect(detectPitch(List.filled(4096, 0.5)), isNull);
    final random = Random(42);
    expect(
      detectPitch(List.generate(4096, (_) => random.nextDouble() - 0.5)),
      isNull,
    );
  });
}
