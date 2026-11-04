import 'dart:math' as math;
import 'dart:typed_data';

import '../metronome/metronome_pattern.dart';

/// 鼓机拍号：`beats` 为每小节拍数，`denominator` 为拍分母。
///
/// 分母为 4 时一拍是一个四分音符（网格占 4 步），为 8 时一拍是一个八分音符（网格占 2 步）。
/// 两种拍号共用十六分音符网格，差别只在“一拍”有多长。
class DrumMeter {
  const DrumMeter(this.beats, this.denominator);

  final int beats;
  final int denominator;

  /// 十六分音符网格中一拍占用的步数。
  int get stepsPerBeat => denominator == 8 ? 2 : 4;

  /// 一小节的总步数。
  int get steps => beats * stepsPerBeat;

  String get label => '$beats/$denominator';

  @override
  bool operator ==(Object other) =>
      other is DrumMeter &&
      other.beats == beats &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(beats, denominator);
}

/// 鼓机可选拍号，顺序与界面一致。
const drumMeters = <DrumMeter>[
  DrumMeter(4, 4),
  DrumMeter(3, 4),
  DrumMeter(2, 4),
  DrumMeter(5, 4),
  DrumMeter(6, 8),
  DrumMeter(7, 8),
];

/// 鼓件轨道顺序，命中矩阵的每一行与之一一对应。
const drumTrackNames = ['底鼓', '军鼓', '踩镲', '拍手', '嗵鼓'];

class DrumPreset {
  const DrumPreset(
    this.name,
    this.hits, {
    this.swing = 0,
    this.meter = const DrumMeter(4, 4),
  });

  final String name;

  /// 五行命中步号，依次为底鼓、军鼓、踩镲、拍手、嗵鼓；某行可为空表示该鼓件不用。
  final List<List<int>> hits;

  final int swing;

  /// 该预设所属拍号，决定网格步数与摇摆规则。
  final DrumMeter meter;
}

const drumPresets = [
  DrumPreset('摇滚', [
    [0, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [4, 12],
    [15],
  ]),
  DrumPreset('放克', [
    [0, 3, 8, 10],
    [4, 12, 15],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [12],
    [7],
  ]),
  DrumPreset('布鲁斯', [
    [0, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [12],
    [10],
  ], swing: 33),
  DrumPreset('流行', [
    [0, 6, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [4, 12],
    [14],
  ]),
  DrumPreset('民谣', [
    [0, 8],
    [4, 12],
    [0, 4, 8, 12],
    [],
    [12],
  ]),
  DrumPreset('朋克', [
    [0, 2, 8, 10],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [4, 12],
    [14],
  ]),
  DrumPreset('金属', [
    [0, 2, 3, 6, 8, 10, 11, 14],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [4, 12],
    [7, 15],
  ]),
  DrumPreset('迪斯科', [
    [0, 4, 8, 12],
    [4, 12],
    [2, 6, 10, 14],
    [4, 12],
    [],
  ]),
  DrumPreset('雷鬼', [
    [8],
    [8],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [4],
    [12],
  ]),
  DrumPreset('嘻哈', [
    [0, 3, 10],
    [4, 12],
    [0, 2, 4, 6, 7, 8, 10, 12, 14, 15],
    [4, 12],
    [7],
  ]),
  DrumPreset('爵士摇摆', [
    [0, 8],
    [4, 12],
    [0, 4, 6, 8, 12, 14],
    [12],
    [14],
  ], swing: 33),
  DrumPreset('拉丁', [
    [0, 6, 8, 14],
    [0, 6, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
    [4, 12],
    [10],
  ]),
  DrumPreset('华尔兹', [
    [0],
    [4],
    [0, 2, 4, 6, 8, 10],
    [],
    [10],
  ], meter: DrumMeter(3, 4)),
  DrumPreset('摇摆圆舞曲', [
    [0, 4, 8],
    [4],
    [0, 2, 4, 6, 8, 10],
    [8],
    [11],
  ], swing: 33, meter: DrumMeter(3, 4)),
  DrumPreset('速朋克', [
    [0, 3, 4],
    [2, 6],
    [0, 1, 2, 3, 4, 5, 6, 7],
    [2, 6],
    [],
  ], meter: DrumMeter(2, 4)),
  DrumPreset('进行曲', [
    [0, 4],
    [2, 6],
    [0, 2, 4, 6],
    [],
    [7],
  ], meter: DrumMeter(2, 4)),
  DrumPreset('渐进摇滚', [
    [0, 12],
    [4, 16],
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 18],
    [16],
    [8, 19],
  ], meter: DrumMeter(5, 4)),
  DrumPreset('五拍摇摆', [
    [0, 10, 12],
    [8, 18],
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 18],
    [],
    [14],
  ], swing: 40, meter: DrumMeter(5, 4)),
  DrumPreset('六八摇摆', [
    [0, 6],
    [2, 8],
    [0, 2, 4, 6, 8, 10],
    [2, 8],
    [11],
  ], meter: DrumMeter(6, 8)),
  DrumPreset('慢布鲁斯', [
    [0],
    [4, 10],
    [0, 2, 4, 6, 8, 10],
    [],
    [9],
  ], swing: 50, meter: DrumMeter(6, 8)),
  DrumPreset('前卫摇滚', [
    [0, 8],
    [4, 12],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
    [4, 12],
    [6],
  ], meter: DrumMeter(7, 8)),
  DrumPreset('巴尔干', [
    [0, 6, 10],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12],
    [],
    [13],
  ], swing: 33, meter: DrumMeter(7, 8)),
];

/// 某个拍号下的预设，按编排顺序返回。
List<DrumPreset> drumPresetsFor(DrumMeter meter) =>
    drumPresets.where((preset) => preset.meter == meter).toList(growable: false);

/// 切换拍号时自动载入的默认预设。
DrumPreset drumDefaultPreset(DrumMeter meter) =>
    drumPresets.firstWhere((preset) => preset.meter == meter);

/// 摇摆延后的步数（以十六分音符步长计）。
///
/// x/4 拍号延后反八分位置及其后的十六分音符；x/8 拍号延后每个八分内的第二个十六分音符。
double drumSwingSteps(int step, int swing, DrumMeter meter) =>
    switch (meter.denominator) {
      8 => step % 2 == 1 ? swing / 100 * 2 : 0.0,
      _ => step % 4 >= 2 ? swing / 100 * 2 : 0.0,
    };

/// Swing delays the off-eighth; 33% gives a near 2:1 shuffle.
/// `framesPerBeat` 是一拍（四分音符）的帧数，步长恒为十六分音符。
int drumStepFrame(
  int step,
  int framesPerBeat,
  int swing, {
  DrumMeter meter = const DrumMeter(4, 4),
}) => ((step + drumSwingSteps(step, swing, meter)) * framesPerBeat / 4).round();

/// 合成一小节鼓机循环。
///
/// `bpm` 统一表示每分钟四分音符数，与拍号无关；`meter` 决定拍数、每拍长度与网格步数。
/// 返回的 `framesPerBeat` 是该拍号下一拍的长度，样本长度恒等于 `framesPerBeat * beats`。
MetronomePattern renderDrums(
  int bpm,
  List<List<bool>> hits,
  List<bool> muted,
  int swing, {
  DrumMeter meter = const DrumMeter(4, 4),
}) {
  final rate = (48000 / bpm).round() * bpm;
  final quarterFrames = rate * 60 ~/ bpm;
  // x/8 拍号的一拍是八分音符，长度是四分音符的一半，BPM 语义保持不变。
  final beatFrames = meter.denominator == 8 ? quarterFrames ~/ 2 : quarterFrames;
  final samples = Float32List(beatFrames * meter.beats);
  final random = math.Random(42);
  for (var track = 0; track < drumTrackNames.length && track < hits.length; track++) {
    if (track < muted.length && muted[track]) continue;
    final duration = switch (track) {
      0 => .32,
      1 => .20,
      2 => .065,
      3 => .16,
      _ => .30,
    };
    final voice = Float32List((rate * duration).round());
    var phase = 0.0;
    var previousNoise = 0.0;
    var band = 0.0;
    for (var i = 0; i < voice.length; i++) {
      final t = i / rate;
      final noise = random.nextDouble() * 2 - 1;
      final high = (noise - previousNoise) / 2;
      previousNoise = noise;
      final attack = math.min(1.0, t / .001);
      final end = math.min(1.0, (voice.length - 1 - i) / (rate * .01));
      final envelope = attack * end;
      switch (track) {
        case 0:
          phase += 2 * math.pi * (48 + 105 * math.exp(-t * 35)) / rate;
          voice[i] = envelope * .75 * math.sin(phase) * math.exp(-t * 17);
          break;
        case 1:
          voice[i] =
              envelope *
              (.38 * noise + .22 * math.sin(2 * math.pi * 185 * t)) *
              math.exp(-t * 25);
          break;
        case 2:
          voice[i] = envelope * .28 * high * math.exp(-t * 65);
          break;
        case 3:
          // 拍手是带通噪声的短促爆发，三次起音模拟手掌回声。
          band += (high - band) * .35;
          voice[i] =
              envelope *
              .32 *
              band *
              (_strike(t, 0) + .6 * _strike(t, .011) + .35 * _strike(t, .022));
          break;
        default:
          // 嗵鼓是带音高下滑的正弦，频率由 150Hz 滑到 80Hz。
          final frequency = 150 - 70 * math.min(1.0, t / .18);
          phase += 2 * math.pi * frequency / rate;
          voice[i] = envelope * .55 * math.sin(phase) * math.exp(-t * 9);
          break;
      }
    }
    for (var step = 0; step < meter.steps && step < hits[track].length; step++) {
      if (!hits[track][step]) continue;
      final offset = drumStepFrame(step, quarterFrames, swing, meter: meter);
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
    beats: meter.beats,
    sampleRate: rate,
    framesPerBeat: beatFrames,
    samples: samples,
  );
}

/// 拍手的一次爆发包络：起点之前静音，之后按 55/s 衰减。
double _strike(double t, double offset) =>
    t < offset ? 0 : math.exp(-(t - offset) * 55);
