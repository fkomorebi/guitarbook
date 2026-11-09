import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/band/chord_progression.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';

/// 4/4 拍号。
const DrumMeter _fourFour = DrumMeter(4, 4);

/// 6/8 拍号。
const DrumMeter _sixEight = DrumMeter(6, 8);

/// 所有性质 id。
const List<String> _allQualities = <String>[
  'maj',
  'min',
  'maj7',
  'm7',
  '7',
  'sus4',
  '6',
  'dim',
  'aug',
  'm7b5',
];

/// 按预设名取一段进行。
ChordProgression _progression(String name) =>
    bandProgressions.firstWhere((item) => item.name == name);

/// 复算每一小节的声部编排，验证音符都来自 voiceChord。
List<List<int>> _voicingsByBar(ChordProgression progression) {
  final voicings = <List<int>>[];
  var referenceTop = 67;
  for (var bar = 0; bar < progression.bars; bar++) {
    final chord =
        progression.chords[(bar ~/ progression.barsPerChord) % progression.chords.length];
    final voicing = voiceChord(chord, referenceTop: referenceTop);
    voicings.add(voicing);
    referenceTop = voicing.last;
  }
  return voicings;
}

/// 取样本里的最大绝对值。
double _peak(List<double> samples) {
  var peak = 0.0;
  for (final value in samples) {
    final magnitude = value.abs();
    if (magnitude > peak) peak = magnitude;
  }
  return peak;
}

void main() {
  group('和弦命名', () {
    test('中文名与简写', () {
      expect(const BandChord(0, 'maj').name, 'C 大和弦');
      expect(const BandChord(9, 'min').name, 'A 小和弦');
      expect(const BandChord(7, '7').name, 'G 属七和弦');
      expect(const BandChord(2, 'm7').name, 'D 小七和弦');
      expect(const BandChord(0, 'maj7').name, 'C 大七和弦');
      expect(const BandChord(5, 'sus4').name, 'F 挂四和弦');
      expect(const BandChord(11, 'dim').name, 'B 减和弦');
      expect(const BandChord(1, 'aug').name, 'C# 增和弦');

      expect(const BandChord(0, 'maj').shortName, 'C');
      expect(const BandChord(9, 'min').shortName, 'Am');
      expect(const BandChord(7, '7').shortName, 'G7');
      expect(const BandChord(2, 'm7').shortName, 'Dm7');
      expect(const BandChord(0, 'maj7').shortName, 'Cmaj7');
      expect(const BandChord(5, 'sus4').shortName, 'Fsus4');
      expect(const BandChord(11, 'dim').shortName, 'Bdim');
      expect(const BandChord(1, 'aug').shortName, 'C#aug');
    });

    test('性质音程', () {
      expect(const BandChord(0, 'maj').intervals, <int>[0, 4, 7]);
      expect(const BandChord(9, 'min').intervals, <int>[0, 3, 7]);
      expect(const BandChord(7, '7').intervals, <int>[0, 4, 7, 10]);
      expect(const BandChord(2, 'm7').intervals, <int>[0, 3, 7, 10]);
      expect(const BandChord(0, 'maj7').intervals, <int>[0, 4, 7, 11]);
      expect(const BandChord(5, 'sus4').intervals, <int>[0, 5, 7]);
      expect(const BandChord(11, 'dim').intervals, <int>[0, 3, 6]);
      expect(const BandChord(1, 'aug').intervals, <int>[0, 4, 8]);
      expect(const BandChord(9, 'm7b5').intervals, <int>[0, 3, 6, 10]);
    });

    test('不认识的性质按大三和弦处理', () {
      const chord = BandChord(0, 'unknown');
      expect(chord.intervals, <int>[0, 4, 7]);
      expect(chord.name, 'C 大和弦');
      expect(chord.shortName, 'C');
    });
  });

  group('内置进行', () {
    test('预设齐全', () {
      expect(bandProgressions, isNotEmpty);
      expect(
        bandProgressions.map((item) => item.name),
        containsAll(<String>[
          '流行进行',
          '摇滚进行',
          '布鲁斯进行',
          '爵士进行',
          '卡农进行',
          '民谣进行',
          '抒情进行',
          '放克进行',
        ]),
      );
    });

    test('每个预设的小节数', () {
      const expected = <String, int>{
        '流行进行': 4,
        '摇滚进行': 4,
        '布鲁斯进行': 12,
        '爵士进行': 4,
        '卡农进行': 8,
        '民谣进行': 4,
        '抒情进行': 8,
        '放克进行': 4,
      };
      for (final progression in bandProgressions) {
        expect(progression.bars, expected[progression.name], reason: progression.name);
        expect(progression.bars, progression.chords.length * progression.barsPerChord);
      }
    });

    test('和弦简写都非空', () {
      for (final progression in bandProgressions) {
        expect(progression.chords, isNotEmpty, reason: progression.name);
        for (final chord in progression.chords) {
          expect(chord.shortName, isNotEmpty, reason: progression.name);
          expect(chord.name, contains('和弦'), reason: progression.name);
        }
        expect(
          progression.chordAt(0),
          same(progression.chords.first),
          reason: progression.name,
        );
      }
    });

    test('流行与摇滚是四小节循环', () {
      expect(_progression('流行进行').bars, 4);
      expect(_progression('摇滚进行').bars, 4);
      expect(_progression('布鲁斯进行').bars, 12);
      expect(_progression('抒情进行').barsPerChord, 2);
      expect(_progression('放克进行').barsPerChord, 2);
    });
  });

  group('声部编排', () {
    test('返回四个落在音区里的音', () {
      for (var root = 0; root < 12; root++) {
        for (final quality in _allQualities) {
          final voicing = voiceChord(BandChord(root, quality));
          expect(voicing, hasLength(4), reason: '$root $quality');
          for (final midi in voicing) {
            expect(midi, inInclusiveRange(52, 72), reason: '$root $quality');
          }
          expect(voicing.toSet(), hasLength(4), reason: '$root $quality');
          for (var i = 1; i < voicing.length; i++) {
            expect(voicing[i], greaterThan(voicing[i - 1]), reason: '$root $quality');
          }
          // 和弦音必须包含根音。
          expect(
            voicing.map((midi) => midi % 12),
            contains(root % 12),
            reason: '$root $quality',
          );
        }
      }
    });

    test('最高音靠近参考高音', () {
      for (final referenceTop in <int>[60, 64, 67, 72]) {
        for (var root = 0; root < 12; root++) {
          for (final quality in _allQualities) {
            final voicing = voiceChord(
              BandChord(root, quality),
              referenceTop: referenceTop,
            );
            expect(
              (voicing.last - referenceTop).abs(),
              lessThanOrEqualTo(12),
              reason: '$root $quality 参考 $referenceTop',
            );
          }
        }
      }
    });

    test('编排是确定的', () {
      for (final quality in _allQualities) {
        final first = voiceChord(BandChord(0, quality));
        final second = voiceChord(BandChord(0, quality));
        expect(first, orderedEquals(second), reason: quality);
      }
    });

    test('C 大和弦是原位编排', () {
      final voicing = voiceChord(const BandChord(0, 'maj'));
      expect(voicing, <int>[60, 64, 67, 72]);
      expect(voicing.first % 12, 0);
    });
  });

  group('和弦编排', () {
    test('音符都落在小节与网格范围内', () {
      for (final progression in bandProgressions) {
        for (final style in ChordPlayStyle.values) {
          for (final meter in <DrumMeter>[_fourFour, _sixEight]) {
            final notes = buildChordNotes(
              progression: progression,
              style: style,
              meter: meter,
            );
            expect(notes, isNotEmpty, reason: '${progression.name} ${style.label}');
            for (final note in notes) {
              expect(note.bar, inInclusiveRange(0, progression.bars - 1));
              expect(note.step, inInclusiveRange(0, meter.steps - 1));
              expect(note.lengthSteps, greaterThanOrEqualTo(1));
              expect(note.step + note.lengthSteps, lessThanOrEqualTo(meter.steps));
            }
          }
        }
      }
    });

    test('流行进行每小节的根音音级正确', () {
      final progression = _progression('流行进行');
      final notes = buildChordNotes(
        progression: progression,
        style: ChordPlayStyle.block,
        meter: _fourFour,
      );
      const expected = <int>[0, 7, 9, 5];
      for (var bar = 0; bar < 4; bar++) {
        final barNotes = notes.where((note) => note.bar == bar).toList();
        expect(barNotes, hasLength(4), reason: '第 $bar 小节');
        expect(barNotes.first.midi % 12, expected[bar], reason: '第 $bar 小节');
        expect(
          barNotes.map((note) => note.midi % 12).toSet(),
          contains(expected[bar]),
          reason: '第 $bar 小节',
        );
      }
    });

    test('音符都来自 voiceChord 的声部', () {
      for (final progression in bandProgressions) {
        for (final style in ChordPlayStyle.values) {
          final notes = buildChordNotes(
            progression: progression,
            style: style,
            meter: _fourFour,
          );
          final voicings = _voicingsByBar(progression);
          for (final note in notes) {
            expect(
              voicings[note.bar],
              contains(note.midi),
              reason: '${progression.name} ${style.label} 第 ${note.bar} 小节',
            );
          }
        }
      }
    });

    test('柱式整小节齐奏一次', () {
      final notes = buildChordNotes(
        progression: _progression('流行进行'),
        style: ChordPlayStyle.block,
        meter: _fourFour,
      );
      expect(notes, hasLength(16));
      for (final note in notes) {
        expect(note.step, 0);
        expect(note.lengthSteps, _fourFour.steps);
      }
    });

    test('律动落在第一拍与第三拍', () {
      final notes = buildChordNotes(
        progression: _progression('流行进行'),
        style: ChordPlayStyle.pulse,
        meter: _fourFour,
      );
      expect(notes, hasLength(32));
      expect(notes.map((note) => note.step).toSet(), <int>{0, 8});
      expect(notes.every((note) => note.lengthSteps == 8), isTrue);
    });

    test('琶音按八分音符网格上下行走', () {
      final notes = buildChordNotes(
        progression: _progression('流行进行'),
        style: ChordPlayStyle.arpeggio,
        meter: _fourFour,
      );
      // 4/4 每小节 8 个八分音符位置。
      expect(notes, hasLength(32));
      final barZero = notes.where((note) => note.bar == 0).toList();
      expect(barZero.map((note) => note.step), <int>[
        0,
        2,
        4,
        6,
        8,
        10,
        12,
        14,
      ]);
      expect(barZero.every((note) => note.lengthSteps == 2), isTrue);
      // 上行再下行。
      expect(barZero.map((note) => note.midi), orderedEquals(<int>[
        60,
        64,
        67,
        72,
        67,
        64,
        60,
        64,
      ]));
    });

    test('扫弦使用固定切分音型', () {
      final notes = buildChordNotes(
        progression: _progression('流行进行'),
        style: ChordPlayStyle.strum,
        meter: _fourFour,
      );
      expect(notes, hasLength(64));
      final barZero = notes.where((note) => note.bar == 0).toList();
      expect(barZero.map((note) => note.step).toSet(), <int>{0, 3, 6, 10});
      expect(barZero.every((note) => note.lengthSteps == 3), isTrue);
    });

    test('6/8 的琶音网格是十六分音符', () {
      final notes = buildChordNotes(
        progression: _progression('流行进行'),
        style: ChordPlayStyle.arpeggio,
        meter: _sixEight,
      );
      final barZero = notes.where((note) => note.bar == 0).toList();
      expect(barZero, hasLength(12));
      expect(barZero.first.step, 0);
      expect(barZero.every((note) => note.lengthSteps == 1), isTrue);
      expect(barZero.last.step, lessThan(_sixEight.steps));
    });
  });

  group('和弦渲染', () {
    test('4/4 120bpm 的循环长度与鼓机一致', () {
      final pattern = renderChordProgression(
        bpm: 120,
        progression: _progression('流行进行'),
        style: ChordPlayStyle.block,
        meter: _fourFour,
      );
      expect(pattern.sampleRate, 48000);
      expect(pattern.framesPerBeat, 24000);
      expect(pattern.beats, 16);
      expect(pattern.samples.length, 384000);
      expect(pattern.samples.length, pattern.framesPerBeat * pattern.beats);
      expect(pattern.samples.any((value) => value != 0), isTrue);
      expect(_peak(pattern.samples), greaterThan(0.05));
      // 软限幅之后不会超过满幅。
      expect(pattern.samples.every((value) => value.abs() <= 1.0), isTrue);
      expect(pattern.toWav().length, 44 + pattern.samples.length * 2);
    });

    test('6/8 拍号的一拍是八分音符', () {
      final pattern = renderChordProgression(
        bpm: 120,
        progression: _progression('流行进行'),
        style: ChordPlayStyle.strum,
        meter: _sixEight,
      );
      expect(pattern.sampleRate, 48000);
      expect(pattern.framesPerBeat, 12000);
      expect(pattern.beats, 24);
      expect(pattern.samples.length, 288000);
      expect(pattern.samples.length, pattern.framesPerBeat * pattern.beats);
      expect(pattern.samples.any((value) => value != 0), isTrue);
      expect(pattern.samples.every((value) => value.abs() <= 1.0), isTrue);
    });

    test('摇摆不改变总帧数', () {
      final straight = renderChordProgression(
        bpm: 100,
        progression: _progression('布鲁斯进行'),
        style: ChordPlayStyle.pulse,
        meter: _fourFour,
      );
      final swung = renderChordProgression(
        bpm: 100,
        progression: _progression('布鲁斯进行'),
        style: ChordPlayStyle.pulse,
        meter: _fourFour,
        swing: 33,
      );
      expect(swung.samples.length, straight.samples.length);
      expect(swung.samples.length, straight.framesPerBeat * straight.beats);
      expect(swung.samples.any((value) => value != 0), isTrue);
    });

    test('所有演奏方式都能渲染出有限且不削顶的循环', () {
      for (final style in ChordPlayStyle.values) {
        for (final meter in <DrumMeter>[_fourFour, _sixEight]) {
          final pattern = renderChordProgression(
            bpm: 100,
            progression: _progression('卡农进行'),
            style: style,
            meter: meter,
          );
          expect(
            pattern.samples.length,
            pattern.framesPerBeat * pattern.beats,
            reason: '${style.label} ${meter.label}',
          );
          expect(
            pattern.samples.every((value) => value.isFinite && value.abs() <= 1.0),
            isTrue,
            reason: '${style.label} ${meter.label}',
          );
          expect(
            pattern.samples.any((value) => value.abs() > 0.05),
            isTrue,
            reason: '${style.label} ${meter.label}',
          );
          // 循环收尾淡出，末样本归零。
          expect(pattern.samples.last, 0, reason: '${style.label} ${meter.label}');
        }
      }
    });

    test('渲染是确定的', () {
      final first = renderChordProgression(
        bpm: 120,
        progression: _progression('爵士进行'),
        style: ChordPlayStyle.arpeggio,
        meter: _fourFour,
      );
      final second = renderChordProgression(
        bpm: 120,
        progression: _progression('爵士进行'),
        style: ChordPlayStyle.arpeggio,
        meter: _fourFour,
      );
      expect(first.samples.toList(), orderedEquals(second.samples.toList()));
    });

    test('音高符合十二平均律', () {
      expect(
        const ChordNote(midi: 69, bar: 0, step: 0, lengthSteps: 4).frequency,
        closeTo(440, 0.001),
      );
      expect(
        const ChordNote(midi: 57, bar: 0, step: 0, lengthSteps: 4).frequency,
        closeTo(220, 0.001),
      );
    });
  });
}
