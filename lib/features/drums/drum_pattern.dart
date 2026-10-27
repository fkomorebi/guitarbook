import 'dart:math' as math;
import 'dart:typed_data';

import '../metronome/metronome_pattern.dart';

class DrumPreset {
  const DrumPreset(this.name, this.hits, {this.swing = 0});
  final String name;
  final List<List<int>> hits;
  final int swing;
}

const drumPresets = [
  DrumPreset('摇滚', [
    [0, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ]),
  DrumPreset('放克', [
    [0, 3, 8, 10],
    [4, 12, 15],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ]),
  DrumPreset('布鲁斯', [
    [0, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ], swing: 33),
];

/// Swing delays the off-eighth; 33% gives a near 2:1 shuffle.
int drumStepFrame(int step, int framesPerBeat, int swing) =>
    ((step + (step % 4 >= 2 ? swing / 100 * 2 : 0)) * framesPerBeat / 4)
        .round();

MetronomePattern renderDrums(
  int bpm,
  List<List<bool>> hits,
  List<bool> muted,
  int swing,
) {
  final rate = (48000 / bpm).round() * bpm;
  final beatFrames = rate * 60 ~/ bpm;
  final samples = Float32List(beatFrames * 4);
  final random = math.Random(42);
  for (var track = 0; track < 3; track++) {
    if (muted[track]) continue;
    final duration = track == 0
        ? .32
        : track == 1
        ? .20
        : .065;
    final voice = Float32List((rate * duration).round());
    var phase = 0.0;
    var previousNoise = 0.0;
    for (var i = 0; i < voice.length; i++) {
      final t = i / rate;
      final noise = random.nextDouble() * 2 - 1;
      final high = (noise - previousNoise) / 2;
      previousNoise = noise;
      phase += 2 * math.pi * (48 + 105 * math.exp(-t * 35)) / rate;
      final attack = math.min(1.0, t / .001);
      final end = math.min(1.0, (voice.length - 1 - i) / (rate * .01));
      voice[i] =
          attack *
          end *
          (track == 0
              ? .75 * math.sin(phase) * math.exp(-t * 17)
              : track == 1
              ? (.38 * noise + .22 * math.sin(2 * math.pi * 185 * t)) *
                    math.exp(-t * 25)
              : .28 * high * math.exp(-t * 65));
    }
    for (var step = 0; step < 16; step++) {
      if (!hits[track][step]) continue;
      final offset = drumStepFrame(step, beatFrames, swing);
      for (var i = 0; i < voice.length; i++) {
        samples[(offset + i) % samples.length] += voice[i];
      }
    }
  }
  // Fixed headroom keeps simultaneous hits safe without pumping between patterns.
  for (var i = 0; i < samples.length; i++) {
    samples[i] = samples[i] / (1 + samples[i].abs());
  }
  return MetronomePattern.rendered(
    bpm: bpm,
    beats: 4,
    sampleRate: rate,
    framesPerBeat: beatFrames,
    samples: samples,
  );
}
