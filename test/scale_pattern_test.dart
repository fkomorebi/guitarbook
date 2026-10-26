import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/scales/scale_pattern.dart';

void main() {
  test('C major contains the expected notes and degrees', () {
    final notes = buildPattern(0, scaleTypes.first, false, 0);
    expect(
      notes.any((n) => n.string == 0 && n.fret == 8 && n.degree == 0),
      isTrue,
    );
    expect(
      notes.any((n) => n.string == 0 && n.fret == 10 && n.degree == 1),
      isTrue,
    );
    expect(notes.any((n) => n.string == 0 && n.fret == 9), isFalse);
  });
  test(
    'all keys and scale patterns contain valid pitches and nonnegative frets',
    () {
      for (var root = 0; root < 12; root++) {
        for (final scale in scaleTypes) {
          for (final three in [false, true]) {
            for (
              var position = 0;
              position < (three ? scale.intervals.length : 5);
              position++
            ) {
              final notes = buildPattern(root, scale, three, position);
              expect(notes, isNotEmpty);
              for (final note in notes) {
                expect(note.fret, inInclusiveRange(0, 30));
                expect(
                  (openStrings[note.string] + note.fret - root) % 12,
                  scale.intervals[note.degree],
                );
              }
              if (three) {
                expect(notes.length, 18);
                for (var string = 0; string < 6; string++) {
                  expect(notes.where((n) => n.string == string).length, 3);
                }
                for (var i = 1; i < notes.length; i++) {
                  final previous =
                      openStrings[notes[i - 1].string] + notes[i - 1].fret;
                  final current = openStrings[notes[i].string] + notes[i].fret;
                  expect(current, greaterThan(previous));
                }
              }
            }
          }
        }
      }
    },
  );
}
