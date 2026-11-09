import 'dart:math' as math;
import 'dart:typed_data';

import '../drums/drum_pattern.dart';
import '../metronome/metronome_pattern.dart';

/// 根音显示名，索引即音级（C=0）。
const List<String> _bandRootNames = <String>[
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];

/// 和弦性质：中文标签、简写后缀与相对根音的半音数。
class _BandQuality {
  const _BandQuality(this.label, this.suffix, this.intervals);

  /// 中文标签，例如「属七」。
  final String label;

  /// 简写后缀，例如「7」。
  final String suffix;

  /// 相对根音的半音数。
  final List<int> intervals;
}

/// 乐队功能使用的和弦性质表。
///
/// 表外的性质 id 一律按大三和弦（maj）处理。
const Map<String, _BandQuality> _bandQualities = <String, _BandQuality>{
  'maj': _BandQuality('大', '', <int>[0, 4, 7]),
  'min': _BandQuality('小', 'm', <int>[0, 3, 7]),
  'maj7': _BandQuality('大七', 'maj7', <int>[0, 4, 7, 11]),
  'm7': _BandQuality('小七', 'm7', <int>[0, 3, 7, 10]),
  '7': _BandQuality('属七', '7', <int>[0, 4, 7, 10]),
  'sus4': _BandQuality('挂四', 'sus4', <int>[0, 5, 7]),
  '6': _BandQuality('六', '6', <int>[0, 4, 7, 9]),
  'dim': _BandQuality('减', 'dim', <int>[0, 3, 6]),
  'aug': _BandQuality('增', 'aug', <int>[0, 4, 8]),
  'm7b5': _BandQuality('半减七', 'm7b5', <int>[0, 3, 6, 10]),
};

/// 性质 id 不认识时的回退性质（大三和弦）。
const _BandQuality _fallbackQuality = _BandQuality(
  '大',
  '',
  <int>[0, 4, 7],
);

/// 一个乐队和弦。
class BandChord {
  const BandChord(this.root, this.quality);

  /// 根音，0-11（C=0）。
  final int root;

  /// 性质 id，例如 maj、min、maj7、m7、7、sus4、6、dim、aug、m7b5。
  final String quality;

  /// 中文名，例如「C 大和弦」「A 小和弦」「G 属七和弦」。
  String get name => '$_rootName ${_quality.label}和弦';

  /// 简写，例如「C」「Am」「G7」「Dm7」「Cmaj7」。
  String get shortName => '$_rootName${_quality.suffix}';

  /// 相对根音的半音数；不认识的性质按大三和弦处理。
  List<int> get intervals => _quality.intervals;

  /// 根音显示名。
  String get _rootName => _bandRootNames[root % 12];

  /// 性质模板。
  _BandQuality get _quality => _bandQualities[quality] ?? _fallbackQuality;
}

/// 一段和弦进行。
class ChordProgression {
  const ChordProgression({
    required this.name,
    required this.chords,
    this.barsPerChord = 1,
  });

  /// 预设名，例如「流行进行」。
  ///
  /// 名字统一带「进行」后缀，免得和鼓机的风格预设（摇滚、布鲁斯等）重名，
  /// 两个面板摆在同一页时用户不会点错。
  final String name;

  /// 和弦序列。
  final List<BandChord> chords;

  /// 每个和弦占几小节。
  final int barsPerChord;

  /// 整段进行的小节数。
  int get bars => chords.length * barsPerChord;

  /// 第 [index] 个和弦。
  BandChord chordAt(int index) => chords[index];
}

/// 内置的和弦进行预设。
const List<ChordProgression> bandProgressions = <ChordProgression>[
  ChordProgression(
    name: '流行进行',
    chords: <BandChord>[
      BandChord(0, 'maj'),
      BandChord(7, 'maj'),
      BandChord(9, 'min'),
      BandChord(5, 'maj'),
    ],
  ),
  ChordProgression(
    name: '摇滚进行',
    chords: <BandChord>[
      BandChord(9, 'min'),
      BandChord(5, 'maj'),
      BandChord(0, 'maj'),
      BandChord(7, 'maj'),
    ],
  ),
  ChordProgression(
    name: '布鲁斯进行',
    chords: <BandChord>[
      BandChord(0, 'maj'),
      BandChord(0, 'maj'),
      BandChord(5, 'maj'),
      BandChord(5, 'maj'),
      BandChord(7, 'maj'),
      BandChord(7, 'maj'),
      BandChord(0, 'maj'),
      BandChord(0, 'maj'),
      BandChord(5, 'maj'),
      BandChord(5, 'maj'),
      BandChord(7, 'maj'),
      BandChord(0, 'maj'),
    ],
  ),
  ChordProgression(
    name: '爵士进行',
    chords: <BandChord>[
      BandChord(2, 'm7'),
      BandChord(7, '7'),
      BandChord(0, 'maj7'),
      BandChord(9, 'm7'),
    ],
  ),
  ChordProgression(
    name: '卡农进行',
    chords: <BandChord>[
      BandChord(0, 'maj'),
      BandChord(7, 'maj'),
      BandChord(9, 'min'),
      BandChord(5, 'maj'),
      BandChord(0, 'maj'),
      BandChord(5, 'maj'),
      BandChord(7, 'maj'),
      BandChord(0, 'maj'),
    ],
  ),
  ChordProgression(
    name: '民谣进行',
    chords: <BandChord>[
      BandChord(7, 'maj'),
      BandChord(2, 'maj'),
      BandChord(4, 'min'),
      BandChord(0, 'maj'),
    ],
  ),
  ChordProgression(
    name: '抒情进行',
    barsPerChord: 2,
    chords: <BandChord>[
      BandChord(9, 'min'),
      BandChord(5, 'maj'),
      BandChord(0, 'maj'),
      BandChord(7, 'maj'),
    ],
  ),
  ChordProgression(
    name: '放克进行',
    barsPerChord: 2,
    chords: <BandChord>[
      BandChord(4, '7'),
      BandChord(2, '7'),
    ],
  ),
];

/// 和弦的演奏方式。
enum ChordPlayStyle {
  /// 柱式：整小节一次齐奏。
  block('柱式'),

  /// 律动：一拍与三拍各弹一次。
  pulse('律动'),

  /// 琶音：上下行逐声部分解。
  arpeggio('琶音'),

  /// 扫弦：切分音型齐奏。
  strum('扫弦');

  const ChordPlayStyle(this.label);

  /// 界面展示用的中文名。
  final String label;
}

/// 和弦编排里的一个音符。
class ChordNote {
  const ChordNote({
    required this.midi,
    required this.bar,
    required this.step,
    required this.lengthSteps,
  });

  /// MIDI 音高，例如 60 = C4。
  final int midi;

  /// 所在小节序号（整段循环内，0 起）。
  final int bar;

  /// 小节内的十六分音符步号（0 起）。
  final int step;

  /// 持续多少个十六分音符步。
  final int lengthSteps;

  /// 该音的频率（Hz）。
  double get frequency => 440 * math.pow(2, (midi - 69) / 12).toDouble();
}

/// 声部允许的最低音高（E3）。
const int _chordLowest = 52;

/// 声部允许的最高音高（C5）。
const int _chordHighest = 72;

/// 第一个小节使用的参考高音。
const int _defaultReferenceTop = 67;

/// 起音时间（秒）。
const double _attackSeconds = 0.005;

/// 指数衰减速度（每秒）。
const double _decayRate = 5.0;

/// 收尾时间（秒），把包络拉到零，避免咔哒声。
const double _releaseSeconds = 0.03;

/// 单个声部的峰值幅度，四个声部叠加也不会削顶。
const double _voiceAmplitude = 0.18;

/// 循环收尾淡出的时间（秒），保证首尾相接没有断点。
const double _loopFadeSeconds = 0.01;

/// 琶音的上下行顺序，循环使用。
const List<int> _arpeggioOrder = <int>[0, 1, 2, 3, 2, 1];

/// 扫弦使用的切分步号。
const List<int> _strumSteps = <int>[0, 3, 6, 10];

/// 把和弦排成四个声部。
///
/// 返回的四个 MIDI 音高都落在 E3~C5（52~72）之间，音高互不相同；
/// [referenceTop] 是期望的最高音（例如上一小节的最高音），
/// 编排结果会尽量靠近它，方便和弦之间平滑过渡。
List<int> voiceChord(BandChord chord, {int referenceTop = 67}) {
  final tones = chord.intervals;
  final candidates = <List<int>>[];
  for (var inversion = 0; inversion < tones.length; inversion++) {
    for (var bass = _chordLowest; bass <= _chordHighest; bass++) {
      if ((chord.root + tones[inversion]) % 12 != bass % 12) continue;
      final stack = _closeStack(chord, tones, inversion, bass);
      if (stack == null) continue;
      final voicing = _completeVoicing(chord, tones, stack);
      if (voicing != null) candidates.add(voicing);
    }
  }
  if (candidates.isEmpty) {
    // 兜底：取低音区里最靠上的根音，保证一定返回四个声部。
    return _fallbackVoicing(chord, tones);
  }
  candidates.sort(_compareVoicings(chord, referenceTop));
  return candidates.first;
}

/// 比较两个声部编排：[referenceTop] 越近的越优先。
int Function(List<int>, List<int>) _compareVoicings(
  BandChord chord,
  int referenceTop,
) {
  return (List<int> a, List<int> b) {
    // 原位和弦优先，其次最靠近参考高音，再次低音更低的。
    final rootPosition = _isRootPosition(chord, a) ? 0 : 1;
    final otherRootPosition = _isRootPosition(chord, b) ? 0 : 1;
    if (rootPosition != otherRootPosition) return rootPosition - otherRootPosition;
    final distance = (a.last - referenceTop).abs().compareTo(
      (b.last - referenceTop).abs(),
    );
    if (distance != 0) return distance;
    final top = a.last.compareTo(b.last);
    if (top != 0) return top;
    final bottom = a.first.compareTo(b.first);
    if (bottom != 0) return bottom;
    for (var i = 0; i < a.length; i++) {
      final step = a[i].compareTo(b[i]);
      if (step != 0) return step;
    }
    return 0;
  };
}

/// 是否是原位（根音在最低声部）。
bool _isRootPosition(BandChord chord, List<int> voicing) =>
    voicing.first % 12 == chord.root % 12;

/// 紧密排列的声部堆叠：每个音都在前一个音之上，不够高就加八度。
///
/// 返回 null 表示超出了可用音区。
List<int>? _closeStack(
  BandChord chord,
  List<int> tones,
  int inversion,
  int bass,
) {
  final stack = <int>[bass];
  for (var i = 1; i < tones.length; i++) {
    final pitchClass = (chord.root + tones[(inversion + i) % tones.length]) % 12;
    var midi = stack.last + ((pitchClass - stack.last) % 12);
    if (midi <= stack.last) midi += 12;
    if (midi > _chordHighest) return null;
    stack.add(midi);
  }
  return stack;
}

/// 补齐第四个声部：三和弦把根音高八度重复，七和弦本身就有四个音。
List<int>? _completeVoicing(
  BandChord chord,
  List<int> tones,
  List<int> stack,
) {
  if (tones.length >= 4) return List<int>.of(stack);
  // 优先重复根音；音区放不下时依次尝试三音、五音。
  for (final offset in <int>[0, tones[1], tones[2]]) {
    final pitchClass = (chord.root + offset) % 12;
    final doubled = stack.firstWhere(
      (midi) => midi % 12 == pitchClass,
      orElse: () => stack.first,
    ) + 12;
    if (doubled > stack.last && doubled <= _chordHighest) {
      return <int>[...stack, doubled];
    }
  }
  return null;
}

/// 兜底声部：低音区根音 + 紧密排列的和弦音。
List<int> _fallbackVoicing(BandChord chord, List<int> tones) {
  final root = chord.root % 12;
  var bass = _chordLowest;
  while (bass % 12 != root && bass < _chordHighest) {
    bass++;
  }
  final voicing = <int>[bass];
  for (final tone in tones.skip(1)) {
    final pitchClass = (chord.root + tone) % 12;
    var midi = voicing.last + ((pitchClass - voicing.last) % 12);
    if (midi <= voicing.last) midi += 12;
    if (midi > _chordHighest) break;
    voicing.add(midi);
  }
  while (voicing.length < 4) {
    final next = voicing.last + 12;
    if (next > _chordHighest) break;
    voicing.add(next);
  }
  return voicing;
}

/// 编排整段和弦进行的音符。
///
/// [bar] 是整段循环里的小节序号，[step] 是小节内的十六分音符步号。
/// 同一小节用同一个和弦，声部参考上一小节的最高音，让进行平滑过渡。
List<ChordNote> buildChordNotes({
  required ChordProgression progression,
  required ChordPlayStyle style,
  required DrumMeter meter,
}) {
  final notes = <ChordNote>[];
  if (progression.chords.isEmpty || progression.bars <= 0) return notes;
  final barsPerChord = progression.barsPerChord <= 0 ? 1 : progression.barsPerChord;
  var referenceTop = _defaultReferenceTop;
  for (var bar = 0; bar < progression.bars; bar++) {
    final chord = progression.chords[(bar ~/ barsPerChord) % progression.chords.length];
    final voicing = voiceChord(chord, referenceTop: referenceTop);
    referenceTop = voicing.last;
    notes.addAll(
      _barNotes(
        bar: bar,
        voicing: voicing,
        style: style,
        meter: meter,
      ),
    );
  }
  return notes;
}

/// 编排一个小节里的音符。
List<ChordNote> _barNotes({
  required int bar,
  required List<int> voicing,
  required ChordPlayStyle style,
  required DrumMeter meter,
}) {
  final notes = <ChordNote>[];
  switch (style) {
    case ChordPlayStyle.block:
      // 柱式：整小节一次齐奏。
      for (final midi in voicing) {
        notes.add(
          ChordNote(midi: midi, bar: bar, step: 0, lengthSteps: meter.steps),
        );
      }
    case ChordPlayStyle.pulse:
      // 律动：一拍与三拍各弹一次。
      final span = 2 * meter.stepsPerBeat;
      for (final hit in <int>[0, span]) {
        if (hit >= meter.steps) continue;
        final length = math.min(span, meter.steps - hit);
        for (final midi in voicing) {
          notes.add(
            ChordNote(midi: midi, bar: bar, step: hit, lengthSteps: length),
          );
        }
      }
    case ChordPlayStyle.arpeggio:
      // 琶音：八分音符网格上上下行走，逐个声部分解。
      final eighth = math.max(1, meter.stepsPerBeat ~/ 2);
      final slots = meter.steps ~/ eighth;
      for (var slot = 0; slot < slots; slot++) {
        final voice = _arpeggioOrder[slot % _arpeggioOrder.length];
        if (voice >= voicing.length) continue;
        notes.add(
          ChordNote(
            midi: voicing[voice],
            bar: bar,
            step: slot * eighth,
            lengthSteps: eighth,
          ),
        );
      }
    case ChordPlayStyle.strum:
      // 扫弦：固定切分音型齐奏。
      for (final hit in _strumSteps) {
        if (hit >= meter.steps) continue;
        // 时长按小节剩余步数截断，避免音符越过小节线。
        final length = math.min(3, meter.steps - hit);
        for (final midi in voicing) {
          notes.add(
            ChordNote(midi: midi, bar: bar, step: hit, lengthSteps: length),
          );
        }
      }
  }
  return notes;
}

/// 把和弦进行渲染成一整段循环音频。
///
/// 采样率与鼓机、低音保持一致：`bpm` 始终是每分钟四分音符数，
/// 样本长度恒等于 `framesPerBeat * beats`，循环首尾相接没有断点。
MetronomePattern renderChordProgression({
  required int bpm,
  required ChordProgression progression,
  required ChordPlayStyle style,
  required DrumMeter meter,
  int swing = 0,
}) {
  final rate = (48000 / bpm).round() * bpm;
  final quarterFrames = rate * 60 ~/ bpm;
  // x/8 拍号的一拍是八分音符，长度是四分音符的一半。
  final beatFrames = meter.denominator == 8 ? quarterFrames ~/ 2 : quarterFrames;
  final barFrames = beatFrames * meter.beats;
  final totalFrames = barFrames * progression.bars;
  final samples = Float32List(totalFrames);
  final notes = buildChordNotes(
    progression: progression,
    style: style,
    meter: meter,
  );
  for (final note in notes) {
    // 落点用鼓机同一套摇摆规则，和弦才会和鼓点对齐。
    final startFrame =
        note.bar * barFrames +
        drumStepFrame(note.step, quarterFrames, swing, meter: meter);
    final voice = _chordVoice(note, rate, quarterFrames);
    for (var i = 0; i < voice.length; i++) {
      final index = startFrame + i;
      if (index >= totalFrames) break;
      samples[index] += voice[i];
    }
  }
  if (totalFrames > 0) {
    // 与鼓机相同的软限幅，叠加后不会削顶。
    for (var i = 0; i < totalFrames; i++) {
      samples[i] = samples[i] / (1 + samples[i].abs());
    }
    // 收尾淡出，循环点不会咔哒一声。
    final fade = math.min(totalFrames, (rate * _loopFadeSeconds).round());
    for (var i = 0; i < fade; i++) {
      final index = totalFrames - fade + i;
      samples[index] *= 1 - i / fade;
    }
    samples[totalFrames - 1] = 0;
  }
  return MetronomePattern.rendered(
    bpm: bpm,
    beats: meter.beats * progression.bars,
    sampleRate: rate,
    framesPerBeat: beatFrames,
    samples: samples,
  );
}

/// 一个和弦音符的音色：基频加少量谐波，带起音、衰减与收尾包络。
Float32List _chordVoice(ChordNote note, int rate, int quarterFrames) {
  final stepFrames = quarterFrames / 4;
  final durationFrames = math.max(1, (note.lengthSteps * stepFrames).round());
  final attackFrames = math.max(1, (rate * _attackSeconds).round());
  final releaseFrames = math.max(1, (rate * _releaseSeconds).round());
  final totalFrames = durationFrames + releaseFrames;
  final voice = Float32List(totalFrames);
  final frequency = note.frequency;
  var peak = 0.0;
  for (var i = 0; i < totalFrames; i++) {
    final t = i / rate;
    final attack = math.min(1.0, i / attackFrames);
    final decay = math.exp(-t * _decayRate);
    final release = math.min(1.0, (totalFrames - 1 - i) / releaseFrames);
    final envelope = attack * decay * release;
    final phase = 2 * math.pi * frequency * t;
    final sample =
        envelope *
        (math.sin(phase) +
            0.35 * math.sin(2 * phase) +
            0.12 * math.sin(3 * phase));
    voice[i] = sample;
    final magnitude = sample.abs();
    if (magnitude > peak) peak = magnitude;
  }
  if (peak > 0) {
    // 每个声部的峰值统一到 0.18，混音后再做软限幅。
    final scale = _voiceAmplitude / peak;
    for (var i = 0; i < totalFrames; i++) {
      voice[i] *= scale;
    }
  }
  return voice;
}
