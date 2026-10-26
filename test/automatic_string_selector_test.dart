import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/tuner/automatic_string_selector.dart';
import 'package:guitarbook/features/tuner/pitch_detector.dart';

void main() {
  test('识别六根空弦及上下偏差，等待稳定后输出', () {
    for (var i = 0; i < guitarStrings.length; i++) {
      for (final cents in [-150, 0, 150]) {
        final selector = AutomaticStringSelector();
        final hz = guitarStrings[i].frequency * math.pow(2, cents / 1200);
        expect(selector.update(hz, 0), isNull);
        expect(selector.update(hz, 93), isNull);
        expect(selector.update(hz, 186), i);
      }
    }
  });

  test('拒绝越界、无效频率且不折叠八度', () {
    final selector = AutomaticStringSelector();
    for (final hz in [null, 0.0, double.nan, double.infinity, 41.2, 659.3]) {
      expect(selector.update(hz, 0), isNull);
      expect(selector.update(hz, 200), isNull);
    }
  });

  test('短暂异弦、静音和长采样间隔均重新确认', () {
    final selector = AutomaticStringSelector();
    expect(selector.update(110, 0), isNull);
    expect(selector.update(110, 200), 1);
    expect(selector.update(146.83, 293), isNull);
    expect(selector.update(110, 386), isNull);
    expect(selector.update(110, 586), 1);
    selector.update(null, 600);
    expect(selector.update(110, 700), isNull);
    expect(selector.update(110, 900), 1);
    expect(selector.update(110, 1400), isNull);
    selector.reset();
    expect(selector.update(110, 1600), isNull);
  });
}
