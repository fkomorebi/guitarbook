import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';

void main() {
  test('meters define their own grid size', () {
    expect(const DrumMeter(4, 4).steps, 16);
    expect(const DrumMeter(3, 4).steps, 12);
    expect(const DrumMeter(2, 4).steps, 8);
    expect(const DrumMeter(5, 4).steps, 20);
    expect(const DrumMeter(6, 8).steps, 12);
    expect(const DrumMeter(7, 8).steps, 14);
    expect(
      drumMeters.map((meter) => meter.label),
      ['4/4', '3/4', '2/4', '5/4', '6/8', '7/8'],
    );
    expect(const DrumMeter(4, 4), const DrumMeter(4, 4));
    expect(const DrumMeter(4, 4), isNot(const DrumMeter(4, 8)));
  });

  test('swing shifts off beats per meter', () {
    const quarter = DrumMeter(4, 4);
    const eighth = DrumMeter(6, 8);
    // x/4：反八分位置及其后的十六分音符后移。
    expect(drumStepFrame(0, 24000, 33, meter: quarter), 0);
    expect(drumStepFrame(2, 24000, 33, meter: quarter), 15960);
    expect(drumStepFrame(4, 24000, 33, meter: quarter), 24000);
    expect(drumSwingSteps(2, 33, quarter), closeTo(.66, .0001));
    expect(drumSwingSteps(1, 33, quarter), 0);
    // x/8：每个八分音符里的第二个十六分音符后移。
    expect(drumStepFrame(0, 24000, 33, meter: eighth), 0);
    expect(drumStepFrame(1, 24000, 33, meter: eighth), 9960);
    expect(drumStepFrame(2, 24000, 33, meter: eighth), 12000);
    expect(drumSwingSteps(1, 50, eighth), 1.0);
    expect(drumSwingSteps(0, 50, eighth), 0);
  });

  test('render length follows the meter', () {
    for (final meter in drumMeters) {
      final hits = [
        for (var track = 0; track < drumTrackNames.length; track++)
          List.generate(meter.steps, (step) => step % 4 == 0),
      ];
      final pattern = renderDrums(
        120,
        hits,
        List.filled(drumTrackNames.length, false),
        0,
        meter: meter,
      );
      expect(pattern.beats, meter.beats);
      expect(pattern.samples.length, pattern.framesPerBeat * meter.beats);
      // BPM 是每分钟四分音符数，x/8 的一拍是四分音符的一半。
      expect(
        pattern.sampleRate * 60,
        pattern.framesPerBeat * 120 * (meter.denominator == 8 ? 2 : 1),
      );
    }
  });

  test('preset steps stay inside the meter grid', () {
    for (final meter in drumMeters) {
      for (final preset in drumPresetsFor(meter)) {
        for (final row in preset.hits) {
          expect(row.every((step) => step < meter.steps), isTrue);
        }
      }
    }
  });
}
