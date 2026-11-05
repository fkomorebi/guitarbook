import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';
import 'package:guitarbook/features/smart_bass/bass_pattern.dart';
import 'package:guitarbook/features/smart_bass/chord_detector.dart';

/// 测试用的 C 大三和弦。
final ChordDetection _cMajor = ChordDetection(
  root: 0,
  quality: 'maj',
  confidence: 0.9,
  intervals: const [0, 4, 7],
);

/// 测试用的 A 小三和弦。
final ChordDetection _aMinor = ChordDetection(
  root: 9,
  quality: 'm',
  confidence: 0.8,
  intervals: const [0, 3, 7],
);

/// 造一份全空白的鼓机命中矩阵。
List<List<bool>> _silentHits(DrumMeter meter) => List.generate(
  drumTrackNames.length,
  (_) => List.filled(meter.steps, false),
);

/// 找出第一个非零样本的位置，找不到返回 -1。
int _firstSound(Float32List samples) {
  for (var i = 0; i < samples.length; i++) {
    if (samples[i] != 0) return i;
  }
  return -1;
}

/// 取样本里的最大绝对值。
double _peak(Float32List samples) {
  var peak = 0.0;
  for (final value in samples) {
    final magnitude = value.abs();
    if (magnitude > peak) peak = magnitude;
  }
  return peak;
}

void main() {
  group('低音小节长度与鼓机循环一致', () {
    test('4/4 拍号与鼓机逐样本同长', () {
      const meter = DrumMeter(4, 4);
      final drums = renderDrums(
        100,
        _silentHits(meter),
        List.filled(drumTrackNames.length, false),
        0,
        meter: meter,
      );
      final bass = renderBass(
        bpm: 100,
        notes: buildBassNotes(
          chord: _cMajor,
          style: BassStyle.rootPulse,
          meter: meter,
          hits: const [],
        ),
        meter: meter,
      );
      expect(bass.samples.length, drums.samples.length);
      expect(bass.samples.length, 28800 * 4);
      expect(bass.sampleRate, 48000);
      expect(bass.framesPerBeat, 28800);
      expect(bass.beats, meter.beats);
      expect(bass.bpm, 100);
    });

    test('6/8 拍号的一拍是八分音符', () {
      const meter = DrumMeter(6, 8);
      final drums = renderDrums(
        100,
        _silentHits(meter),
        List.filled(drumTrackNames.length, false),
        0,
        meter: meter,
      );
      final bass = renderBass(bpm: 100, notes: const [], meter: meter);
      expect(bass.samples.length, drums.samples.length);
      expect(bass.framesPerBeat, 14400);
      expect(bass.samples.length, 14400 * 6);
      expect(bass.sampleRate, 48000);
    });
  });

  group('低音编排', () {
    test('followKick 跟随底鼓落点', () {
      const meter = DrumMeter(4, 4);
      final hits = _silentHits(meter);
      hits[0][0] = true;
      hits[0][8] = true;
      final notes = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.followKick,
        meter: meter,
        hits: hits,
      );
      expect(notes.map((note) => note.step), [0, 8]);
      expect(notes.map((note) => note.midi), [
        notes.first.midi,
        notes.first.midi,
      ]);
      expect(notes.first.midi % 12, 0);
    });

    test('底鼓为空时退化为第一拍', () {
      const meter = DrumMeter(4, 4);
      final notes = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.followKick,
        meter: meter,
        hits: _silentHits(meter),
      );
      expect(notes.length, 1);
      expect(notes.first.step, 0);
      final noHits = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.followKick,
        meter: meter,
        hits: const [],
      );
      expect(noHits.length, 1);
      expect(noHits.first.step, 0);
    });

    test('rootPulse 首拍、中点与末尾点缀', () {
      const meter = DrumMeter(4, 4);
      final notes = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.rootPulse,
        meter: meter,
        hits: const [],
      );
      expect(notes.map((note) => note.step), [0, 8, 14]);
      // 首拍与中点都是根音。
      expect(notes[0].midi, notes[1].midi);
      // 末尾点缀是五度或八度根音。
      expect(notes[2].midi - notes[0].midi, anyOf(7, 12));
    });

    test('6/8 的中点按拍计算', () {
      const meter = DrumMeter(6, 8);
      final notes = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.rootPulse,
        meter: meter,
        hits: const [],
      );
      expect(notes.map((note) => note.step), [0, 6, 11]);
    });

    test('walking 每拍一个和弦音，首音是根音', () {
      const meter = DrumMeter(4, 4);
      final notes = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.walking,
        meter: meter,
        hits: const [],
      );
      expect(notes.length, meter.beats);
      expect(notes.map((note) => note.step), [0, 4, 8, 12]);
      expect(notes.first.midi % 12, 0);
      // 最后一个音回到根音或八度根音。
      expect(notes.last.midi, anyOf(notes.first.midi, notes.first.midi + 12));
      // 每个和弦音都留在根音的一个八度之内。
      for (final note in notes) {
        expect((note.midi - notes.first.midi).abs(), lessThanOrEqualTo(12));
      }
    });

    test('根音始终落在低音区', () {
      const meter = DrumMeter(4, 4);
      for (var root = 0; root < 12; root++) {
        final chord = ChordDetection(
          root: root,
          quality: 'maj',
          confidence: 0.9,
          intervals: const [0, 4, 7],
        );
        final notes = buildBassNotes(
          chord: chord,
          style: BassStyle.followKick,
          meter: meter,
          hits: const [],
        );
        expect(notes.first.midi, inInclusiveRange(28, 45));
        expect(notes.first.midi % 12, root);
      }
    });
  });

  group('低音渲染', () {
    test('首拍附近有能量，不是静音', () {
      const meter = DrumMeter(4, 4);
      final notes = buildBassNotes(
        chord: _aMinor,
        style: BassStyle.walking,
        meter: meter,
        hits: const [],
      );
      final bass = renderBass(bpm: 100, notes: notes, meter: meter);
      expect(bass.samples.any((value) => value != 0), isTrue);
      expect(_firstSound(bass.samples), lessThan(1000));
      expect(_peak(bass.samples), greaterThan(0.1));
      // 软限幅之后不会超过满幅。
      expect(_peak(bass.samples), lessThanOrEqualTo(1.0));
    });

    test('与鼓机共用摇摆规则，音符落在摇摆后的位置', () {
      const meter = DrumMeter(4, 4);
      const note = BassNote(midi: 36, step: 2, lengthSteps: 4);
      final bass = renderBass(
        bpm: 100,
        notes: const [note],
        meter: meter,
        swing: 33,
      );
      final quarterFrames = 48000 * 60 ~/ 100;
      final offset = drumStepFrame(2, quarterFrames, 33, meter: meter);
      expect(offset, greaterThan(quarterFrames ~/ 2));
      // 摇摆落点之前保持静音，能量从落点开始。
      expect(bass.samples.sublist(0, offset).every((v) => v == 0), isTrue);
      expect(
        bass.samples.sublist(offset + 1, offset + 400).any((v) => v != 0),
        isTrue,
      );
    });

    test('渲染是确定性的', () {
      const meter = DrumMeter(4, 4);
      final notes = buildBassNotes(
        chord: _cMajor,
        style: BassStyle.rootPulse,
        meter: meter,
        hits: const [],
      );
      final first = renderBass(bpm: 100, notes: notes, meter: meter);
      final second = renderBass(bpm: 100, notes: notes, meter: meter);
      expect(first.samples.toList(), orderedEquals(second.samples.toList()));
    });

    test('音高符合十二平均律', () {
      expect(
        const BassNote(midi: 33, step: 0, lengthSteps: 4).frequency,
        closeTo(55, 0.001),
      );
      expect(
        const BassNote(midi: 69, step: 0, lengthSteps: 4).frequency,
        closeTo(440, 0.001),
      );
    });
  });
}
