import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/looper/loop_samples.dart';
import 'package:guitarbook/features/looper/smart_loop_take.dart';

Uint8List tone(double seconds, double amplitude) {
  final data = ByteData((seconds * loopSampleRate).round() * 2);
  for (var i = 0; i < data.lengthInBytes ~/ 2; i++) {
    data.setInt16(
      i * 2,
      (math.sin(2 * math.pi * 220 * i / loopSampleRate) * amplitude * 32767)
          .round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

void main() {
  test(
    'calibration and transient rejection, preserving inner rests and quiet decay',
    () {
      final smart = SmartLoopTake(thresholdDb: -45);
      smart.add(tone(.5, .001));
      expect(smart.calibrating, isFalse);
      smart.add(tone(.02, .8));
      smart.add(tone(.5, .001));
      expect(smart.started, isFalse);
      smart.add(tone(.5, .1));
      expect(smart.started, isTrue);
      smart.add(tone(.5, 0)); // Inner rest must remain.
      smart.add(tone(.5, .1));
      smart.add(tone(.5, .003)); // Below onset, above release threshold.
      smart.add(tone(.5, 0));
      smart.add(tone(.02, .8)); // A short end click must not extend the take.
      smart.add(tone(1.5, .001));
      expect(smart.done, isTrue);
      expect(smart.trimmedFrames / loopSampleRate, closeTo(2.13, .02));
      final result = smart.take.finish(length: smart.trimmedFrames, offset: 0);
      expect(result.first, 0);
      expect(result.last, 0);
      expect(result.sublist(26000, 45000).every((x) => x == 0), isTrue);
      expect(result.sublist(74000, 93000).any((x) => x.abs() > .001), isTrue);
    },
  );

  test('PCM byte chunk boundaries produce identical decisions and samples', () {
    final bytes = Uint8List.fromList([
      ...tone(.5, 0),
      ...tone(.7, .1),
      ...tone(2.1, 0),
    ]);
    final whole = SmartLoopTake(thresholdDb: -45)..add(bytes);
    final split = SmartLoopTake(thresholdDb: -45);
    for (var i = 0; i < bytes.length; i += 731) {
      split.add(
        Uint8List.sublistView(bytes, i, math.min(i + 731, bytes.length)),
      );
    }
    expect(split.done, isTrue);
    expect(split.trimmedFrames, whole.trimmedFrames);
    expect(
      split.take.finish(length: split.trimmedFrames, offset: 0),
      whole.take.finish(length: whole.trimmedFrames, offset: 0),
    );
  });

  test(
    'silence times out, continuous recording is bounded, threshold is adjustable',
    () {
      final silent = SmartLoopTake(thresholdDb: -45)..add(tone(30, 0));
      expect(silent.timedOut, isTrue);
      expect(silent.started, isFalse);
      final sustained = SmartLoopTake(thresholdDb: -45)
        ..add(tone(.5, 0))
        ..add(tone(31, .1));
      expect(sustained.done, isTrue);
      expect(sustained.take.count, maxLoopFrames);
      final sensitive = SmartLoopTake(thresholdDb: -60)
        ..add(tone(.5, 0))
        ..add(tone(.2, .003));
      final resistant = SmartLoopTake(thresholdDb: -20)
        ..add(tone(.5, 0))
        ..add(tone(.2, .003));
      expect(sensitive.started, isTrue);
      expect(resistant.started, isFalse);
    },
  );
}
