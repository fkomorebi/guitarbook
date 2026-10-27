import 'chord_lesson.dart';

class ChordRoot {
  const ChordRoot(this.name, this.pitch, this.letter);
  final String name;
  final int pitch;
  final int letter;
}

// Letter indices C D E F G A B. Explicit spellings keep thirds and fifths legible.
const chordRoots = [
  ChordRoot('C', 0, 0),
  ChordRoot('D♭', 1, 1),
  ChordRoot('D', 2, 1),
  ChordRoot('E♭', 3, 2),
  ChordRoot('E', 4, 2),
  ChordRoot('F', 5, 3),
  ChordRoot('F♯', 6, 3),
  ChordRoot('G', 7, 4),
  ChordRoot('A♭', 8, 5),
  ChordRoot('A', 9, 5),
  ChordRoot('B♭', 10, 6),
  ChordRoot('B', 11, 6),
];

class TriadQuality {
  const TriadQuality(
    this.name,
    this.suffix,
    this.intervals,
    this.degrees,
    this.explanation,
  );
  final String name;
  final String suffix;
  final List<int> intervals;
  final List<String> degrees;
  final String explanation;
}

const triadQualities = [
  TriadQuality(
    '大三和弦',
    '',
    [0, 4, 7],
    ['1', '3', '5'],
    '从根音数，大三度是 4 个半音，纯五度是 7 个半音。相邻构成音之间是“大三度 + 小三度”。',
  ),
  TriadQuality(
    '小三和弦',
    'm',
    [0, 3, 7],
    ['1', '♭3', '5'],
    '把同根音大三和弦的三度音降低一个半音，保留根音和五度音。相邻构成音之间是“小三度 + 大三度”。',
  ),
  TriadQuality(
    '减三和弦',
    'dim',
    [0, 3, 6],
    ['1', '♭3', '♭5'],
    '在小三和弦的基础上再降低五度音一个半音。相邻构成音之间是两个小三度。',
  ),
  TriadQuality(
    '增三和弦',
    'aug',
    [0, 4, 8],
    ['1', '3', '♯5'],
    '在大三和弦的基础上升高五度音一个半音。相邻构成音之间是两个大三度；它的等距结构会带来等音重解释，这里仍按所选根音命名。',
  ),
];

const inversionNames = ['原位', '第一转位', '第二转位'];
const toneRoles = ['根音', '三度音', '五度音'];
const guitarOpenMidi = [40, 45, 50, 55, 59, 64];

class TriadExample {
  const TriadExample(this.root, this.quality, this.inversion);
  final ChordRoot root;
  final TriadQuality quality;
  final int inversion;

  String get name => '${root.name}${quality.suffix}';
  String get formula => quality.degrees.join(' · ');
  List<String> get notes => [for (var i = 0; i < 3; i++) _spell(i)];
  List<int> get toneOrder => [for (var i = 0; i < 3; i++) (inversion + i) % 3];

  String _spell(int tone) {
    const letters = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
    const natural = [0, 2, 4, 5, 7, 9, 11];
    final letter = (root.letter + tone * 2) % 7;
    var alteration =
        (root.pitch + quality.intervals[tone] - natural[letter]) % 12;
    if (alteration > 6) alteration -= 12;
    final sign = alteration < 0 ? '♭' : '♯';
    return '${letters[letter]}${List.filled(alteration.abs(), sign).join()}';
  }

  List<int> _fretsFor(TriadQuality selectedQuality) {
    final pitches = <int>[];
    for (final tone in toneOrder) {
      var midi = 60 + root.pitch + selectedQuality.intervals[tone];
      while (pitches.isNotEmpty && midi <= pitches.last) {
        midi += 12;
      }
      pitches.add(midi);
    }
    return [for (var i = 0; i < 3; i++) pitches[i] - guitarOpenMidi[i + 3]];
  }

  GuitarChord get voicing {
    // Use the same octave for all qualities at a given root/inversion, so changing
    // a third or fifth cannot unexpectedly move the whole comparison an octave.
    final lowest = [
      for (final type in triadQualities) ..._fretsFor(type),
    ].reduce((a, b) => a < b ? a : b);
    final octave = lowest ~/ 12;
    final frets = [for (final fret in _fretsFor(quality)) fret - 12 * octave];
    return GuitarChord(name, [-1, -1, -1, ...frets], [0, 0, 0, 0, 0, 0]);
  }

  List<GuitarChord> get arpeggio => [
    for (final i in [0, 1, 2, 1, 0])
      GuitarChord(
        notes[toneOrder[i]],
        [for (var s = 0; s < 6; s++) s == i + 3 ? voicing.frets[s] : -1],
        [0, 0, 0, 0, 0, 0],
      ),
  ];
}

TriadExample openChordTheory(GuitarChord chord) => TriadExample(
  chordRoots.firstWhere((root) => root.name == chord.name[0]),
  triadQualities[chord.name.endsWith('m') ? 1 : 0],
  0,
);

String openStringRole(GuitarChord chord, int index) {
  if (chord.frets[index] < 0) return '${6 - index} 弦：不弹';
  final example = openChordTheory(chord);
  final pitch = (guitarOpenMidi[index] + chord.frets[index]) % 12;
  final tone = example.quality.intervals.indexWhere(
    (interval) => (example.root.pitch + interval) % 12 == pitch,
  );
  return '${6 - index} 弦：${example.notes[tone]} · ${example.quality.degrees[tone]}（${toneRoles[tone]}）';
}
