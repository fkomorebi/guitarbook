import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/tuner/tuning_feedback.dart';

void main() {
  double hz(double cents) => 110.0 * math.pow(2, cents / 1200);

  test(
    'requires sustained accuracy, tolerates boundary jitter and releases',
    () {
      final feedback = TuningFeedback();
      for (var t = 0; t <= 500; t += 100) {
        feedback.update(hz(2), 110, t);
        expect(feedback.inTune, isFalse);
      }
      feedback.update(hz(2), 110, 600);
      expect(feedback.inTune, isTrue);
      feedback.update(hz(6), 110, 700);
      expect(feedback.inTune, isTrue);
      feedback.update(hz(10), 110, 800);
      expect(feedback.inTune, isFalse);
    },
  );

  test('smooths jitter and expires stale confirmation without new audio', () {
    final feedback = TuningFeedback();
    feedback.update(hz(-20), 110, 0);
    feedback.update(hz(20), 110, 100);
    expect(feedback.cents, inExclusiveRange(-20, 20));
    feedback.update(null, 110, 200);
    expect(feedback.cents, isNotNull);
    feedback.expire(550);
    expect(feedback.cents, isNotNull);
    expect(feedback.stale, isTrue);
    expect(feedback.inTune, isFalse);
    feedback.expire(3100);
    expect(feedback.cents, isNull);
  });

  test(
    'stale readings release confirmation and resume without old smoothing',
    () {
      final feedback = TuningFeedback();
      for (var t = 0; t <= 600; t += 100) {
        feedback.update(110, 110, t);
      }
      expect(feedback.inTune, isTrue);
      feedback.expire(1050);
      expect(feedback.stale, isTrue);
      expect(feedback.inTune, isFalse);
      feedback.update(hz(30), 110, 1100);
      expect(feedback.stale, isFalse);
      expect(feedback.cents, closeTo(30, .001));
      feedback.interruptConfirmation();
      expect(feedback.cents, isNotNull);
      feedback.expire(4099);
      expect(feedback.cents, isNotNull);
      feedback.expire(4100);
      expect(feedback.cents, isNull);
    },
  );

  test('missing estimates interrupt confirmation and reset clears history', () {
    final feedback = TuningFeedback();
    feedback.update(110, 110, 0);
    feedback.update(110, 110, 300);
    feedback.update(null, 110, 400);
    feedback.update(110, 110, 500);
    feedback.update(110, 110, 800);
    expect(feedback.inTune, isFalse);
    feedback.reset();
    feedback.update(hz(30), 110, 900);
    expect(feedback.cents, closeTo(30, .001));
  });
}
