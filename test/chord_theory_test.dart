import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/chords/chord_theory.dart';
import 'package:guitarbook/features/chords/chord_lesson.dart';

void main() {
  test('所有根音性质转位的实际吉他音高、音程和琶音相符', () {
    for (final root in chordRoots) {
      for (final quality in triadQualities) {
        for (var inversion = 0; inversion < 3; inversion++) {
          final example = TriadExample(root, quality, inversion);
          final shape = example.voicing;
          expect(shape.frets.take(3), everyElement(-1));
          final pitches = [
            for (var i = 3; i < 6; i++) guitarOpenMidi[i] + shape.frets[i],
          ];
          expect(pitches[0], lessThan(pitches[1]));
          expect(pitches[1], lessThan(pitches[2]));
          for (var i = 0; i < 3; i++) {
            expect(shape.frets[i + 3], inInclusiveRange(0, 22));
            expect(
              pitches[i] % 12,
              (root.pitch + quality.intervals[(inversion + i) % 3]) % 12,
            );
          }
          final events = example.arpeggio;
          expect(events.length, 5);
          for (var i = 0; i < events.length; i++) {
            final s = [3, 4, 5, 4, 3][i];
            expect(events[i].frets.where((f) => f >= 0), hasLength(1));
            expect(events[i].frets[s], shape.frets[s]);
          }
          expect(shape.instruction(3), isNot(contains('0 指')));
        }
      }
    }
  });

  test('同根音同转位比较性质时只移动被改变的构成音，不整组跳八度', () {
    for (final root in chordRoots) {
      for (var inversion = 0; inversion < 3; inversion++) {
        final major = TriadExample(root, triadQualities[0], inversion);
        final minor = TriadExample(root, triadQualities[1], inversion);
        for (var i = 0; i < 3; i++) {
          expect(
            minor.voicing.frets[i + 3] - major.voicing.frets[i + 3],
            major.toneOrder[i] == 1 ? -1 : 0,
          );
        }
      }
    }
  });

  test('音名按三度与五度拼写，保留等音理论身份', () {
    expect(TriadExample(chordRoots[0], triadQualities[0], 0).notes, [
      'C',
      'E',
      'G',
    ]);
    expect(TriadExample(chordRoots[9], triadQualities[1], 0).notes, [
      'A',
      'C',
      'E',
    ]);
    expect(TriadExample(chordRoots[1], triadQualities[1], 0).notes, [
      'D♭',
      'F♭',
      'A♭',
    ]);
    expect(TriadExample(chordRoots[6], triadQualities[3], 0).notes, [
      'F♯',
      'A♯',
      'C♯♯',
    ]);
    expect(TriadExample(chordRoots[11], triadQualities[2], 0).notes, [
      'B',
      'D',
      'F',
    ]);
  });

  test('开放和弦所有可弹弦只包含其三种构成音且角色说明完整', () {
    for (final chord in beginnerChords.values) {
      final example = openChordTheory(chord);
      final allowed = example.quality.intervals
          .map((i) => (example.root.pitch + i) % 12)
          .toSet();
      final pitches = {
        for (var i = 0; i < 6; i++)
          if (chord.frets[i] >= 0) (guitarOpenMidi[i] + chord.frets[i]) % 12,
      };
      expect(pitches, allowed);
      for (var i = 0; i < 6; i++) {
        expect(() => openStringRole(chord, i), returnsNormally);
      }
    }
    expect(openStringRole(beginnerChords['C']!, 4), '2 弦：C · 1（根音）');
  });
}
