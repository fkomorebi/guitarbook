class ScaleType {
  const ScaleType(this.name, this.intervals, this.degrees);
  final String name;
  final List<int> intervals;
  final List<String> degrees;
}

const scaleTypes = [
  ScaleType(
    '大调 / 伊奥尼亚',
    [0, 2, 4, 5, 7, 9, 11],
    ['1', '2', '3', '4', '5', '6', '7'],
  ),
  ScaleType(
    '自然小调 / 爱奥利亚',
    [0, 2, 3, 5, 7, 8, 10],
    ['1', '2', '♭3', '4', '5', '♭6', '♭7'],
  ),
  ScaleType(
    '和声小调',
    [0, 2, 3, 5, 7, 8, 11],
    ['1', '2', '♭3', '4', '5', '♭6', '7'],
  ),
  ScaleType(
    '旋律小调（上行）',
    [0, 2, 3, 5, 7, 9, 11],
    ['1', '2', '♭3', '4', '5', '6', '7'],
  ),
  ScaleType('大调五声音阶', [0, 2, 4, 7, 9], ['1', '2', '3', '5', '6']),
  ScaleType('小调五声音阶', [0, 3, 5, 7, 10], ['1', '♭3', '4', '5', '♭7']),
  ScaleType('小调布鲁斯', [0, 3, 5, 6, 7, 10], ['1', '♭3', '4', '♭5', '5', '♭7']),
  ScaleType(
    '多利亚',
    [0, 2, 3, 5, 7, 9, 10],
    ['1', '2', '♭3', '4', '5', '6', '♭7'],
  ),
  ScaleType(
    '弗里几亚',
    [0, 1, 3, 5, 7, 8, 10],
    ['1', '♭2', '♭3', '4', '5', '♭6', '♭7'],
  ),
  ScaleType(
    '利底亚',
    [0, 2, 4, 6, 7, 9, 11],
    ['1', '2', '3', '♯4', '5', '6', '7'],
  ),
  ScaleType(
    '混合利底亚',
    [0, 2, 4, 5, 7, 9, 10],
    ['1', '2', '3', '4', '5', '6', '♭7'],
  ),
  ScaleType(
    '洛克里亚',
    [0, 1, 3, 5, 6, 8, 10],
    ['1', '♭2', '♭3', '4', '♭5', '♭6', '♭7'],
  ),
];
const rootNames = [
  'C',
  'C♯ / D♭',
  'D',
  'D♯ / E♭',
  'E',
  'F',
  'F♯ / G♭',
  'G',
  'G♯ / A♭',
  'A',
  'A♯ / B♭',
  'B',
];
const noteNames = [
  'C',
  'C♯/D♭',
  'D',
  'D♯/E♭',
  'E',
  'F',
  'F♯/G♭',
  'G',
  'G♯/A♭',
  'A',
  'A♯/B♭',
  'B',
];
// Low E to high E, in MIDI semitones.
const openStrings = [40, 45, 50, 55, 59, 64];
const cagedShapes = ['E', 'D', 'C', 'A', 'G'];

class ScaleNote {
  const ScaleNote(this.string, this.fret, this.degree);
  final int string;
  final int fret;
  final int degree;
}

List<ScaleNote> buildPattern(
  int root,
  ScaleType scale,
  bool threeNotes,
  int position,
) {
  final rootFret = (root - 4) % 12;
  final result = <ScaleNote>[];
  if (threeNotes) {
    var pitch = 40 + (rootFret + scale.intervals[position]) % 12;
    for (var string = 0; string < 6; string++) {
      for (var count = 0; count < 3; count++) {
        final degree = scale.intervals.indexOf((pitch - root) % 12);
        result.add(ScaleNote(string, pitch - openStrings[string], degree));
        do {
          pitch++;
        } while (!scale.intervals.contains((pitch - root) % 12));
      }
    }
  } else {
    const starts = [0, 2, 4, 7, 9];
    const ends = [4, 5, 8, 10, 12];
    var start = rootFret + starts[position];
    var end = rootFret + ends[position];
    if (start >= 12) {
      start -= 12;
      end -= 12;
    }
    for (var string = 0; string < 6; string++) {
      for (var fret = start; fret <= end; fret++) {
        final degree = scale.intervals.indexOf(
          (openStrings[string] + fret - root) % 12,
        );
        if (degree >= 0) result.add(ScaleNote(string, fret, degree));
      }
    }
  }
  if (result.any((note) => note.fret < 0)) {
    return result
        .map((note) => ScaleNote(note.string, note.fret + 12, note.degree))
        .toList();
  }
  return result;
}
