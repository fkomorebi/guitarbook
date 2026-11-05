import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/smart_bass/chord_detector.dart';

const int _sampleRate = 48000;
const int _windowSize = 4096;

/// 合成一段吉他音色：基频 + 二次/三次谐波，可叠加少量噪声。
Float32List _synthChord(
  List<double> frequencies, {
  double noise = 0,
  int seed = 7,
  double harmonic2 = 0.5,
  double harmonic3 = 0.33,
}) {
  final random = math.Random(seed);
  final samples = Float32List(_windowSize);
  var peak = 0.0;
  for (var i = 0; i < _windowSize; i++) {
    var value = 0.0;
    for (final frequency in frequencies) {
      final phase = 2 * math.pi * frequency * i / _sampleRate;
      value +=
          math.sin(phase) +
          harmonic2 * math.sin(2 * phase) +
          harmonic3 * math.sin(3 * phase);
    }
    if (noise > 0) {
      value += noise * (random.nextDouble() * 2 - 1);
    }
    samples[i] = value;
    if (value.abs() > peak) peak = value.abs();
  }
  if (peak > 0) {
    final gain = 0.85 / peak;
    for (var i = 0; i < _windowSize; i++) {
      samples[i] *= gain;
    }
  }
  return samples;
}

/// 合成一段白噪声。
Float32List _whiteNoise({int seed = 3, double amplitude = 0.3}) {
  final random = math.Random(seed);
  final samples = Float32List(_windowSize);
  for (var i = 0; i < _windowSize; i++) {
    samples[i] = amplitude * (random.nextDouble() * 2 - 1);
  }
  return samples;
}

void main() {
  group('detectChord', () {
    test('识别 C 大三和弦', () {
      final result = detectChord(_synthChord(<double>[130.81, 164.81, 196.00]));
      expect(result, isNotNull);
      expect(result!.root, 0);
      expect(result.quality, 'maj');
      expect(result.intervals, <int>[0, 4, 7]);
      expect(result.pitchClasses, <int>[0, 4, 7]);
      expect(result.confidence, greaterThan(0.35));
      expect(result.confidence, lessThanOrEqualTo(1.0));
      expect(result.name, 'C大和弦');
    });

    test('识别 A 小三和弦', () {
      final result = detectChord(_synthChord(<double>[110.0, 130.81, 164.81]));
      expect(result, isNotNull);
      expect(result!.root, 9);
      expect(result.quality, 'min');
      expect(result.pitchClasses, <int>[9, 0, 4]);
      expect(result.name, 'A小和弦');
    });

    test('识别 G 属七和弦', () {
      final result = detectChord(
        _synthChord(<double>[98.0, 123.47, 146.83, 174.61]),
      );
      expect(result, isNotNull);
      expect(result!.root, 7);
      expect(result.quality, '7');
      expect(result.pitchClasses, <int>[7, 11, 2, 5]);
      expect(result.qualityLabel, '属七');
    });

    test('带噪声时仍能识别 C 大三和弦', () {
      final result = detectChord(
        _synthChord(<double>[130.81, 164.81, 196.00], noise: 0.08),
      );
      expect(result, isNotNull);
      expect(result!.root, 0);
    });

    test('全静音返回 null', () {
      expect(detectChord(Float32List(_windowSize)), isNull);
    });

    test('白噪声返回 null', () {
      expect(detectChord(_whiteNoise()), isNull);
    });

    test('极低电平信号返回 null', () {
      final samples = _synthChord(<double>[130.81, 164.81, 196.00]);
      for (var i = 0; i < samples.length; i++) {
        samples[i] *= 0.001;
      }
      expect(detectChord(samples), isNull);
    });

    test('置信度不足时返回 null', () {
      final samples = _synthChord(<double>[130.81, 164.81, 196.00]);
      final result = detectChord(samples, minConfidence: 0.99);
      expect(result, isNull);
    });

    test('输入为空时返回 null', () {
      expect(detectChord(Float32List(0)), isNull);
    });

    test('相同输入得到相同结果', () {
      final samples = _synthChord(<double>[110.0, 130.81, 164.81]);
      final first = detectChord(samples);
      final second = detectChord(samples);
      expect(first?.root, second?.root);
      expect(first?.quality, second?.quality);
      expect(first?.confidence, second?.confidence);
    });
  });

  group('和弦模板', () {
    test('质量标签齐全', () {
      for (final quality in chordQualityTemplates.keys) {
        expect(chordQualityLabels.containsKey(quality), isTrue);
      }
    });

    test('每个模板都以根音 0 开头', () {
      for (final intervals in chordQualityTemplates.values) {
        expect(intervals.first, 0);
      }
    });

    test('音级名与音级数一致', () {
      expect(pitchClassNames.length, 12);
      expect(pitchClassNames.first, 'C');
      expect(pitchClassNames.last, 'B');
    });
  });

  group('ChordDetection', () {
    test('展示名与音级计算正确', () {
      const detection = ChordDetection(
        root: 9,
        quality: 'min',
        confidence: 0.8,
        intervals: <int>[0, 3, 7],
      );
      expect(detection.qualityLabel, '小');
      expect(detection.name, 'A小和弦');
      expect(detection.pitchClasses, <int>[9, 0, 4]);
    });

    test('未知质量回退为质量 id', () {
      const detection = ChordDetection(
        root: 0,
        quality: 'unknown',
        confidence: 0.5,
        intervals: <int>[0, 4, 7],
      );
      expect(detection.qualityLabel, 'unknown');
      expect(detection.name, 'Cunknown和弦');
    });
  });
}
