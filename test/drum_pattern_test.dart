import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';

void main() {
  test('presets render finite bounded loops at all tempo limits', () {
    for (final bpm in [30, 100, 137, 240]) {
      for (final preset in drumPresets) {
        final hits = [
          for (final row in preset.hits) List.generate(16, row.contains),
        ];
        final pattern = renderDrums(bpm, hits, [
          false,
          false,
          false,
        ], preset.swing);
        expect(pattern.samples.length, pattern.framesPerBeat * 4);
        expect(pattern.sampleRate * 60, pattern.framesPerBeat * bpm);
        expect(pattern.samples.every((v) => v.isFinite && v.abs() < 1), isTrue);
        expect(pattern.samples.any((v) => v.abs() > .05), isTrue);
        expect(pattern.toWav().length, 44 + pattern.samples.length * 2);
      }
    }
  });
  test('swing delays off eighths and mute removes all sound', () {
    expect(drumStepFrame(0, 24000, 33), 0);
    expect(drumStepFrame(2, 24000, 33), 15960);
    expect(drumStepFrame(4, 24000, 33), 24000);
    final pattern = renderDrums(
      100,
      List.generate(3, (_) => List.filled(16, true)),
      [true, true, true],
      60,
    );
    expect(pattern.samples.every((v) => v == 0), isTrue);
  });
}
