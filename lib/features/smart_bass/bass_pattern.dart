import 'dart:math' as math;
import 'dart:typed_data';

import '../drums/drum_pattern.dart';
import '../metronome/metronome_pattern.dart';
import 'chord_detector.dart';

/// 低音编排风格。
enum BassStyle {
  /// 跟随鼓机底鼓的落点弹奏根音。
  followKick('跟底鼓'),

  /// 根音律动：一拍与中点弹根音，尾部加五度点缀。
  rootPulse('根音律动'),

  /// 走动低音：按和弦音逐拍走位。
  walking('走动低音');

  const BassStyle(this.label);

  /// 界面展示用的中文名。
  final String label;
}

/// 一个低音音符。
class BassNote {
  const BassNote({
    required this.midi,
    required this.step,
    required this.lengthSteps,
  });

  /// MIDI 音高，例如 33 = A1。
  final int midi;

  /// 十六分音符网格步号（0 起）。
  final int step;

  /// 持续多少个十六分音符步。
  final int lengthSteps;

  /// 该音的频率（Hz）。
  double get frequency => 440 * math.pow(2, (midi - 69) / 12).toDouble();
}

/// 低音根音的可用音区下限：E1。
const int _bassLowest = 28;

/// 低音根音的可用音区上限：A2。
const int _bassHighest = 45;

/// 起音时间（秒），落在电贝斯自然的 5~10 ms 区间。
const double _attackSeconds = 0.008;

/// 指数衰减速度（每秒），越大越短促。
const double _decayRate = 5.0;

/// 收尾时间（秒），把包络拉到零，避免咔哒声。
const double _releaseSeconds = 0.02;

/// 单个音符的峰值幅度。
const double _notePeak = 0.5;

/// 根音律动里中点与末尾点缀之间的最长间隔（以十六分音符步长计）。
const int _maxSpan = 8;

/// 由和弦与鼓机网格编排出一小节的低音音符。
///
/// [chord] 决定根音与和弦音，[style] 决定编排方式，[hits] 是鼓机命中矩阵
/// （第 0 行是底鼓）。[swing] 只是为了和鼓机接口保持一致，摇摆延迟在
/// [renderBass] 阶段生效。
List<BassNote> buildBassNotes({
  required ChordDetection chord,
  required BassStyle style,
  required DrumMeter meter,
  required List<List<bool>> hits,
  int swing = 0,
}) {
  final root = _rootMidi(chord);
  final palette = _chordPalette(chord);
  return switch (style) {
    BassStyle.followKick => _followKickNotes(root, meter, hits),
    BassStyle.rootPulse => _rootPulseNotes(root, meter),
    BassStyle.walking => _walkingNotes(root, palette, meter),
  };
}

/// 把低音音符渲染成一小节的循环音频。
///
/// 输出的小节长度与同一 bpm/拍号下的鼓机循环完全一致，
/// 这样两条循环用同一个播放引擎同时播放时不会漂移。
MetronomePattern renderBass({
  required int bpm,
  required List<BassNote> notes,
  required DrumMeter meter,
  int swing = 0,
}) {
  final rate = (48000 / bpm).round() * bpm;
  final quarterFrames = rate * 60 ~/ bpm;
  // x/8 拍号的一拍是八分音符，与鼓机保持同一套换算。
  final beatFrames = meter.denominator == 8
      ? quarterFrames ~/ 2
      : quarterFrames;
  final samples = Float32List(beatFrames * meter.beats);
  if (samples.isNotEmpty) {
    for (final note in notes) {
      final voice = _bassVoice(note, rate, quarterFrames);
      // 落点用鼓机同一套摇摆规则，鼓点与低音才会对齐。
      final offset = drumStepFrame(
        note.step,
        quarterFrames,
        swing,
        meter: meter,
      );
      for (var i = 0; i < voice.length; i++) {
        samples[(offset + i) % samples.length] += voice[i];
      }
    }
    // 与鼓机相同的软限幅，叠加后不会削顶。
    for (var i = 0; i < samples.length; i++) {
      samples[i] = samples[i] / (1 + samples[i].abs());
    }
  }
  return MetronomePattern.rendered(
    bpm: bpm,
    beats: meter.beats,
    sampleRate: rate,
    framesPerBeat: beatFrames,
    samples: samples,
  );
}

/// 和弦音相对根音的半音数，优先使用检测结果。
///
/// 检测不到音程时按和弦性质推导，识别不出性质时按大三和弦处理。
List<int> _chordOffsets(ChordDetection chord) {
  if (chord.intervals.isNotEmpty) return chord.intervals;
  return switch (chord.quality) {
    'm' || 'min' || 'minor' => const [0, 3, 7],
    'm7' || 'min7' => const [0, 3, 7, 10],
    'maj7' => const [0, 4, 7, 11],
    '7' || 'dom' || 'dom7' => const [0, 4, 7, 10],
    '6' => const [0, 4, 7, 9],
    'dim' || 'dim7' => const [0, 3, 6],
    'm7b5' => const [0, 3, 6, 10],
    'aug' => const [0, 4, 8],
    'sus2' => const [0, 2, 7],
    'sus' || 'sus4' => const [0, 5, 7],
    _ => const [0, 4, 7],
  };
}

/// 根-三-五-七四个位置的和弦音（相对根音的半音数）。
///
/// 三和弦没有七音时，第四个位置用八度根音收尾。
List<int> _chordPalette(ChordDetection chord) {
  final offsets = _chordOffsets(chord).toSet().toList()..sort();
  final palette = <int>[0];
  for (final offset in offsets.where((value) => value > 0).take(3)) {
    palette.add(offset);
  }
  while (palette.length < 4) {
    palette.add(12);
  }
  return palette;
}

/// 根音在低音区的 MIDI 音高。
///
/// 优先选择能让整个和弦都落在低音区里的最低根音。
int _rootMidi(ChordDetection chord) {
  final pitchClass = chord.root % 12;
  final offsets = _chordOffsets(chord);
  var highest = 0;
  for (final offset in offsets) {
    if (offset > highest) highest = offset;
  }
  final candidates = <int>[
    for (var midi = _bassLowest; midi <= _bassHighest; midi++)
      if (midi % 12 == pitchClass) midi,
  ];
  if (candidates.isEmpty) return 36;
  for (final candidate in candidates) {
    if (candidate + highest <= _bassHighest) return candidate;
  }
  return candidates.first;
}

/// 低音根音的 MIDI 音高（低音区 E1~A2）。
///
/// 控制器补「落点音」时要用同一个根音，避免和编排里的音高对不上。
int bassRootMidi(ChordDetection chord) => _rootMidi(chord);

/// 和弦音的音高：始终保持在根音上下一个八度之内。
///
/// 根音落在 E1~A2 的低音区，和弦音允许上下八度跳跃，
/// 这样走动低音既能走起来又不会跑出贝斯音域。
int _toneMidi(int rootMidi, int offset) => rootMidi + offset;

/// 末尾点缀的五度；太高时改用下方五度，保证仍在低音区。
int _ornamentMidi(int root) {
  final above = root + 7;
  if (above <= _bassHighest) return above;
  final below = root - 5;
  if (below >= _bassLowest) return below;
  return root + 12;
}

/// 两个落点之间的音符长度，最多持续半小节。
int _span(int start, int end, int total) {
  final span = math.min(end, total) - start;
  return math.max(1, math.min(_maxSpan, span));
}

/// 跟随鼓机底鼓的落点弹奏根音。
List<BassNote> _followKickNotes(
  int root,
  DrumMeter meter,
  List<List<bool>> hits,
) {
  final kicks = <int>[];
  if (hits.isNotEmpty) {
    final row = hits[0];
    for (var step = 0; step < row.length && step < meter.steps; step++) {
      if (row[step]) kicks.add(step);
    }
  }
  if (kicks.isEmpty) {
    // 底鼓为空时退化为每小节第一拍弹一次根音。
    return [
      BassNote(
        midi: root,
        step: 0,
        lengthSteps: _span(0, meter.steps, meter.steps),
      ),
    ];
  }
  return [
    for (var i = 0; i < kicks.length; i++)
      BassNote(
        midi: root,
        step: kicks[i],
        lengthSteps: _span(
          kicks[i],
          i + 1 < kicks.length ? kicks[i + 1] : meter.steps,
          meter.steps,
        ),
      ),
  ];
}

/// 根音律动：首拍与中点弹根音，末尾加五度点缀。
List<BassNote> _rootPulseNotes(int root, DrumMeter meter) {
  // x/8 拍号按「拍」计算中点，而不是按四分音符。
  final mid = (meter.beats ~/ 2) * meter.stepsPerBeat;
  final ornament = meter.steps - (meter.stepsPerBeat ~/ 2);
  final notes = <BassNote>[];
  if (mid > 0 && mid < ornament) {
    notes.add(BassNote(midi: root, step: 0, lengthSteps: mid));
    notes.add(BassNote(midi: root, step: mid, lengthSteps: ornament - mid));
  } else {
    notes.add(BassNote(midi: root, step: 0, lengthSteps: ornament));
  }
  notes.add(
    BassNote(
      midi: _ornamentMidi(root),
      step: ornament,
      lengthSteps: math.max(1, meter.steps - ornament),
    ),
  );
  return notes;
}

/// 走动低音：每个四分音符（x/8 拍号每拍）弹一个和弦音。
List<BassNote> _walkingNotes(int root, List<int> palette, DrumMeter meter) {
  final notes = <BassNote>[];
  for (var i = 0; i < meter.beats; i++) {
    final step = i * meter.stepsPerBeat;
    final isLast = i == meter.beats - 1;
    // 最后一个音回到根音或八度根音。
    final midi = isLast
        ? _toneMidi(root, 12)
        : _toneMidi(root, palette[i % palette.length]);
    final remaining = meter.steps - step;
    final length = isLast ? remaining : math.min(meter.stepsPerBeat, remaining);
    notes.add(
      BassNote(midi: midi, step: step, lengthSteps: math.max(1, length)),
    );
  }
  return notes;
}

/// 一个音符的电贝斯音色：基频正弦加少量谐波，带起音与收尾包络。
Float32List _bassVoice(BassNote note, int rate, int quarterFrames) {
  final stepFrames = quarterFrames / 4;
  final frames = math.max(1, (note.lengthSteps * stepFrames).round());
  final voice = Float32List(frames);
  final frequency = note.frequency;
  final attackFrames = math.max(1, (rate * _attackSeconds).round());
  final releaseFrames = math.max(1, (rate * _releaseSeconds).round());
  var peak = 0.0;
  for (var i = 0; i < frames; i++) {
    final t = i / rate;
    final attack = math.min(1.0, i / attackFrames);
    final release = math.min(1.0, (frames - 1 - i) / releaseFrames);
    final decay = math.exp(-t * _decayRate);
    final envelope = attack * decay * release;
    final phase = 2 * math.pi * frequency * t;
    final sample =
        envelope *
        (math.sin(phase) +
            0.35 * math.sin(2 * phase) +
            0.15 * math.sin(3 * phase));
    voice[i] = sample;
    final magnitude = sample.abs();
    if (magnitude > peak) peak = magnitude;
  }
  if (peak > 0) {
    // 每个音符的峰值统一到 0.5，混音后再做软限幅。
    final scale = _notePeak / peak;
    for (var i = 0; i < frames; i++) {
      voice[i] *= scale;
    }
  }
  return voice;
}
