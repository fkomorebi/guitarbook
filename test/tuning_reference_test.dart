import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/tuner/automatic_string_selector.dart';
import 'package:guitarbook/features/tuner/pitch_detector.dart';
import 'package:guitarbook/features/tuner/tuning_reference.dart';

void main() {
  test('440 Hz 基准与吉他弦表完全一致', () {
    expect(TuningReference.standard.scale, closeTo(1.0, 1e-12));
    for (var i = 0; i < guitarStrings.length; i++) {
      expect(
        TuningReference.standard.stringFrequency(i),
        closeTo(guitarStrings[i].frequency, 1e-12),
      );
    }
  });

  test('432 Hz 基准下六根空弦频率整体缩放', () {
    expect(TuningReference.natural.scale, closeTo(432 / 440, 1e-12));
    const expected = [80.91, 108.0, 144.16, 192.43, 242.45, 323.63];
    final strings = TuningReference.natural.strings;
    expect(strings.length, guitarStrings.length);
    for (var i = 0; i < strings.length; i++) {
      expect(strings[i].frequency, closeTo(expected[i], 0.01));
      expect(strings[i].label, guitarStrings[i].label);
      expect(
        TuningReference.natural.stringFrequency(i),
        closeTo(guitarStrings[i].frequency * 432 / 440, 1e-9),
      );
    }
  });

  test('两个基准之间的音分差恒为约 -31.77 音分', () {
    for (var i = 0; i < guitarStrings.length; i++) {
      // 432 Hz 目标相对 440 Hz 目标低约 31.77 音分（centsBetween 为负表示偏低）。
      expect(
        centsBetween(
          TuningReference.natural.stringFrequency(i),
          TuningReference.standard.stringFrequency(i),
        ),
        closeTo(-31.77, 0.01),
      );
    }
  });

  test('432 Hz 基准下六根空弦都能被识别', () {
    for (var i = 0; i < guitarStrings.length; i++) {
      final selector = AutomaticStringSelector()
        ..reference = TuningReference.natural;
      final hz = TuningReference.natural.stringFrequency(i);
      expect(selector.update(hz, 0), isNull);
      expect(selector.update(hz, 93), isNull);
      expect(selector.update(hz, 186), i);
    }
  });

  test('432 Hz 基准下 108 Hz 命中 5 弦 A2', () {
    final selector = AutomaticStringSelector()
      ..reference = TuningReference.natural;
    expect(selector.update(108.0, 0), isNull);
    expect(selector.update(108.0, 93), isNull);
    expect(selector.update(108.0, 186), 1);
    expect(
      centsBetween(108.0, TuningReference.natural.stringFrequency(1)),
      closeTo(0, 1e-9),
    );
  });

  test('切回 440 Hz 后 108 Hz 仍落在 A2 的 ±180 音分窗口内', () {
    // 识别窗口是 ±180 音分，108 Hz 距 440 Hz 基准的 A2 只有 31.77 音分，
    // 所以弦号不变；两种基准的差别体现在音分偏差而不是识别结果上。
    final selector = AutomaticStringSelector();
    expect(selector.update(108.0, 0), isNull);
    expect(selector.update(108.0, 186), 1);
    expect(
      centsBetween(108.0, TuningReference.standard.stringFrequency(1)),
      closeTo(-31.77, 0.01),
    );
  });

  test('基准切换会改变识别结果：90.5 Hz 在 440 Hz 下是 6 弦，432 Hz 下无匹配', () {
    // 90.5 Hz 在 440 Hz 基准下距 6 弦 E2 约 162 音分，仍在 ±180 窗口内；
    // 432 Hz 的 E2 更低，90.5 Hz 超出该窗口又够不到 A2，因此识别不出。
    final standard = AutomaticStringSelector();
    expect(standard.update(90.5, 0), isNull);
    expect(standard.update(90.5, 186), 0);

    final natural = AutomaticStringSelector()
      ..reference = TuningReference.natural;
    expect(natural.update(90.5, 0), isNull);
    expect(natural.update(90.5, 186), isNull);
  });

  test('切换基准会清空确认状态', () {
    final selector = AutomaticStringSelector();
    expect(selector.update(110.0, 0), isNull);
    expect(selector.update(110.0, 186), 1);
    selector.reference = TuningReference.natural;
    // 确认状态已清空，需要重新稳定 180 毫秒才会给出弦号。
    expect(selector.update(110.0, 200), isNull);
    expect(selector.update(110.0, 400), 1);
  });

  test('重复设置同一基准不会打断当前确认', () {
    final selector = AutomaticStringSelector();
    expect(selector.update(110.0, 0), isNull);
    selector.reference = TuningReference.standard;
    expect(selector.update(110.0, 186), 1);
  });
}
