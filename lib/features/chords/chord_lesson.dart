class GuitarChord {
  const GuitarChord(this.name, this.frets, this.fingers);

  final String name;
  // From string 6 to string 1; -1 means do not play.
  final List<int> frets;
  final List<int> fingers;

  String instruction(int index) {
    final fret = frets[index];
    return '${6 - index} 弦：${fret < 0
        ? '不弹'
        : fret == 0
        ? '空弦'
        : '$fret 品${fingers[index] > 0 ? ' · ${fingers[index]} 指' : ''}'}';
  }
}

const beginnerChords = <String, GuitarChord>{
  'Em': GuitarChord('Em', [0, 2, 2, 0, 0, 0], [0, 2, 3, 0, 0, 0]),
  'Am': GuitarChord('Am', [-1, 0, 2, 2, 1, 0], [0, 0, 2, 3, 1, 0]),
  'C': GuitarChord('C', [-1, 3, 2, 0, 1, 0], [0, 3, 2, 0, 1, 0]),
  'G': GuitarChord('G', [3, 2, 0, 0, 0, 3], [2, 1, 0, 0, 0, 3]),
  'D': GuitarChord('D', [-1, -1, 0, 2, 3, 2], [0, 0, 0, 1, 3, 2]),
  'E': GuitarChord('E', [0, 2, 2, 1, 0, 0], [0, 2, 3, 1, 0, 0]),
};

class ChordLesson {
  const ChordLesson(this.title, this.chords, this.tip);
  final String title;
  final List<String> chords;
  final String tip;
}

const chordLessons = [
  ChordLesson('1 · 第一次按和弦', ['Em', 'Am'], '先分别摆好 Em、Am，逐弦拨响；再慢慢交替，不要求速度。'),
  ChordLesson('2 · 加入 C 和弦', ['Am', 'C'], 'Am 换 C 时，试着保留食指和中指的位置，只移动无名指。'),
  ChordLesson('3 · 认识 G 和 D', ['G', 'D'], 'G 可弹六根弦，D 从四弦开始。先找对右手起始弦，再转换。'),
  ChordLesson('4 · 小段落练习', [
    'E',
    'Am',
    'Em',
    'Am',
  ], '每个和弦慢数四拍，第一拍向下扫一次；换好再继续，先求清楚。'),
];
