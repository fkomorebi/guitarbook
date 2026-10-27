import 'chord_lesson.dart';
import 'chord_theory.dart';

class CourseQuestion {
  const CourseQuestion(this.prompt, this.choices, this.correct, this.reason);
  final String prompt;
  final List<String> choices;
  final int correct;
  final String reason;
}

class CourseScore {
  const CourseScore(this.title, this.chords, this.caption);
  final String title;
  final List<GuitarChord> chords;
  final String caption;
}

class ChordCourseLesson {
  const ChordCourseLesson({
    required this.title,
    required this.goal,
    required this.sections,
    required this.scores,
    required this.tasks,
    required this.questions,
    required this.reference,
  });
  final String title;
  final String goal;
  final List<(String, String)> sections;
  final List<CourseScore> scores;
  final List<String> tasks;
  final List<CourseQuestion> questions;
  final String reference;
}

GuitarChord _single(String label, int string, int fret) => GuitarChord(
  label,
  [for (var s = 6; s >= 1; s--) s == string ? fret : -1],
  const [0, 0, 0, 0, 0, 0],
);

TriadExample _triad(int root, int quality, [int inversion = 0]) =>
    TriadExample(chordRoots[root], triadQualities[quality], inversion);

GuitarChord _inverted(int inversion) {
  final example = _triad(0, 0, inversion);
  return GuitarChord(
    inversion == 0 ? 'C' : 'C/${example.notes[inversion]}',
    example.voicing.frets,
    example.voicing.fingers,
  );
}

class SeventhLessonShape {
  const SeventhLessonShape(
    this.name,
    this.formula,
    this.notes,
    this.intervals,
    this.frets,
  );
  final String name;
  final String formula;
  // Root, third, fifth, seventh, with correct diatonic spelling.
  final List<String> notes;
  final List<int> intervals;
  final List<int> frets;
  GuitarChord get chord => GuitarChord(name, frets, const [0, 0, 0, 0, 0, 0]);
}

// Four-string open voicings: from string 5 to 2, root–fifth–seventh–third.
const seventhLessonShapes = [
  SeventhLessonShape(
    'Cmaj7',
    '1 · 3 · 5 · 7',
    ['C', 'E', 'G', 'B'],
    [0, 4, 7, 11],
    [-1, 3, 5, 4, 5, -1],
  ),
  SeventhLessonShape(
    'C7',
    '1 · 3 · 5 · ♭7',
    ['C', 'E', 'G', 'B♭'],
    [0, 4, 7, 10],
    [-1, 3, 5, 3, 5, -1],
  ),
  SeventhLessonShape(
    'Cm7',
    '1 · ♭3 · 5 · ♭7',
    ['C', 'E♭', 'G', 'B♭'],
    [0, 3, 7, 10],
    [-1, 3, 5, 3, 4, -1],
  ),
  SeventhLessonShape(
    'Cm7♭5',
    '1 · ♭3 · ♭5 · ♭7',
    ['C', 'E♭', 'G♭', 'B♭'],
    [0, 3, 6, 10],
    [-1, 3, 4, 3, 4, -1],
  ),
  SeventhLessonShape(
    'Cdim7',
    '1 · ♭3 · ♭5 · ♭♭7',
    ['C', 'E♭', 'G♭', 'B♭♭'],
    [0, 3, 6, 9],
    [-1, 3, 4, 2, 4, -1],
  ),
];

final chordCourse = <ChordCourseLesson>[
  ChordCourseLesson(
    title: '音名、琴弦与品位',
    goal: '看见一个谱上数字，能指出该弹哪根弦、哪一品，并区分音名、品位和手指编号。',
    reference: '第 1、3、4 章；引言',
    sections: [
      (
        '先给声音一个名字',
        '常用音名是 C、D、E、F、G、A、B；唱名 do、re、mi 是另一套表达。升号 ♯ 把音升高半音，降号 ♭ 把音降低半音。同一根弦相邻两品相差一个半音，跨两品是一个全音。B 到 C、E 到 F 只有半音，不能把所有相邻字母都当成全音。',
      ),
      (
        '再把音放到琴上',
        '标准调弦从最粗的六弦到最细的一弦是 E、A、D、G、B、E。两个 E 的音名相同，但一弦的 E 比六弦的 E 高两个八度。品从琴头向琴身递增；空弦不按，记为 0。',
      ),
      (
        '读下面这个例子',
        'TAB 的最上面是一弦，最下面是六弦。一弦依次弹 0、1、2、3 品，得到 E、F、F♯、G。这里的 3 是三品，不是三指；公式里的 3 则表示三度音。先学会区分这三种数字，以后就不会只记手的形状。',
      ),
    ],
    scores: [
      CourseScore('一弦上的四个相邻音', [
        for (var i = 0; i < 4; i++) _single(['E', 'F', 'F♯', 'G'][i], 1, i),
      ], '从左到右一次只弹一根弦。注意 E→F 只移动一品。此例没有规定节奏。'),
    ],
    tasks: [
      '画：在纸上画六条横线，标出一弦到六弦和标准空弦音名。',
      '说：指出“一弦三品”“三指”“三度音”分别描述什么。',
      '弹：慢慢弹一弦 0、1、2、3 品，同时说 E、F、F♯、G。',
    ],
    questions: [
      CourseQuestion(
        '同一根弦从空弦移到一品，升高多少？',
        ['一个半音', '一个全音', '一个八度'],
        0,
        '空弦到一品与任何相邻品一样，只增加一个半音。全音需要两个半音。',
      ),
      CourseQuestion(
        '和弦公式里的“3”主要表示什么？',
        ['必须用三指', '必须按三品', '三度音的角色'],
        2,
        '音程公式描述音与根音的关系。具体品位取决于根音、琴弦和位置，手指编号是另一个问题。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '音程：先数度数，再辨性质',
    goal: '能解释大三度、小三度和纯五度，并用同弦品位距离核对半音数。',
    reference: '第 10–11 章，书内 33–38 页',
    sections: [
      (
        '度数回答“跨了几个音名”',
        '从 C 数到 E，把两端一起数：C、D、E，共三个字母位置，因此是三度。C 到 E♭ 也仍然是三度，因为最后的字母还是 E。升降号不会把“三度”变成另一个度数。',
      ),
      (
        '性质回答“准确相隔多远”',
        'C→E 是 4 个半音，叫大三度；C→E♭ 是 3 个半音，叫小三度。C→G 跨 C、D、E、F、G 五个字母位置，相隔 7 个半音，叫纯五度。度数与半音数要一起看，不能只看相隔几品就省略音名字母。',
      ),
      (
        '把抽象距离变成可检查的位置',
        '三弦五品是 C。沿同一根弦上移到八品是 E♭（+3），九品是 E（+4），十二品是 G（+7）。下面是单弦音程示意，需要换把逐个弹，并不是让一只手同时跨住五到十二品。',
      ),
    ],
    scores: [
      CourseScore('从同一个 C 出发比较距离', [
        _single('C', 3, 5),
        _single('E♭', 3, 8),
        _single('E', 3, 9),
        _single('G', 3, 12),
      ], '每次比较都以 C 为起点：+3、+4、+7 个半音。不要把后面相邻两列的差当成与根音的距离。'),
    ],
    tasks: [
      '画：写出 C→E♭、C→E、C→G，并在旁边标 3、4、7 个半音。',
      '说：说明为什么 C→E 和 C→E♭ 都是三度。',
      '弹：每弹出一个目标音，都先回到三弦五品 C，再弹目标音。',
    ],
    questions: [
      CourseQuestion(
        'C→E♭ 与 C→E 的区别是什么？',
        ['度数不同', '都是三度，半音数不同', '没有区别'],
        1,
        '二者都跨三个字母位置；3 个半音是小三度，4 个半音是大三度。',
      ),
      CourseQuestion(
        '三弦五品 C 上方的纯五度在同弦几品？',
        ['八品', '九品', '十二品'],
        2,
        '纯五度上行 7 个半音；同弦一品一个半音，因此 5 + 7 = 12 品。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '把大三和弦真正搭出来',
    goal: '从根音推导三个构成音，而不是直接背 C 或 D 的手型。',
    reference: '第 13–14 章，书内 41、44–45 页',
    sections: [
      (
        '三和弦是三种音的关系',
        '以一个音作根音，再加上它上方的大三度和纯五度，就得到大三和弦。公式写作 1、3、5；相对根音的半音数是 0、4、7。公式中的 1 是根音，不是“一弦”。',
      ),
      (
        '一步一步算 C 大三和弦',
        '先写根音 C，再找大三度 E，最后找纯五度 G，得到 C–E–G。也可以从 C 大调 C、D、E、F、G、A、B 取第 1、3、5 级。C→E 是大三度，E→G 是小三度；“大三度 + 小三度”叠起来得到纯五度。',
      ),
      (
        '换根音，再算一次',
        'D 大调是 D、E、F♯、G、A、B、C♯，所以 D 大三和弦是 D–F♯–A。F♯ 不是装饰符号：D→F 只有 3 个半音，会变成小三和弦。下面只用三根高音弦，每根弦放一个构成音，让你看清根音、三度和五度。',
      ),
    ],
    scores: [
      CourseScore(
        'C 与 D：公式不变，音名改变',
        [_triad(0, 0).voicing, _triad(2, 0).voicing],
        'C：三弦五品 C、二弦五品 E、一弦三品 G；D：三弦七品 D、二弦七品 F♯、一弦五品 A。同列三个音一起弹。',
      ),
    ],
    tasks: [
      '画：先不看谱，写出 C 和 D 的 1、3、5，再核对升降号。',
      '说：分别说出“根音是什么、三度是什么、五度是什么”。',
      '弹：先逐弦检查三个音，再一起拨响；不用扫到其余三根弦。',
    ],
    questions: [
      CourseQuestion(
        'D 大三和弦应包含哪三个音？',
        ['D–F–A', 'D–F♯–A', 'D–G–A'],
        1,
        '大三和弦必须有大三度。D→F♯ 是 4 个半音，D→A 是 7 个半音。',
      ),
      CourseQuestion(
        '大三和弦中，从根音到五度音共多少半音？',
        ['3', '4', '7'],
        2,
        '从根音算纯五度是 7 个半音。4 是根音到大三度的距离，不是到五度的距离。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '大与小：只改变三度音',
    goal: '能在根音与五度保持不变时，把大三和弦改成小三和弦。',
    reference: '第 13–14 章，书内 42、45 页',
    sections: [
      (
        '保留两个音，只降低一个音',
        '小三和弦的公式是 1、♭3、5，相对根音是 0、3、7 个半音。与同根音大三和弦相比，只把三度音降低半音，根音与五度不变。C–E–G 变成 C–E♭–G，就是 C 小三和弦 Cm。',
      ),
      (
        '看清哪根弦在变化',
        '下面 C 的三个音在三弦五品、二弦五品、一弦三品。变 Cm 时，只有二弦从五品 E 移到四品 E♭；三弦的 C 和一弦的 G 不动。这是理解手型变化的原因，不只是换一张图。',
      ),
      (
        '♭3 不代表音名必须有降号',
        'A 大三和弦是 A–C♯–E，把 C♯ 降半音得到 C，A 小三和弦就是 A–C–E。这里的 C 没写降号，但相对于 A 的大三度 C♯，它仍是 ♭3。公式中的升降是相对于根音的大调参照。',
      ),
    ],
    scores: [
      CourseScore('C → Cm：二弦降低一品', [
        _triad(0, 0).voicing,
        _triad(0, 1).voicing,
      ], '依次弹 C 和 Cm，指出保持不变的 C、G，再说出 E→E♭。不要求把某种听感背成唯一答案。'),
    ],
    tasks: [
      '画：写出 C→Cm 和 A→Am，圈出唯一改变的音。',
      '说：解释 Am 的三度音为什么是 C，而不是 C♭。',
      '弹：保持三弦与一弦位置不变，只在二弦五品和四品之间切换。',
    ],
    questions: [
      CourseQuestion(
        '把 C 大三和弦改成 Cm，应该怎样做？',
        ['把三个音全部降低一品', '只把 E 降到 E♭', '只把 G 降到 G♭'],
        1,
        '只有三度改变：C–E–G → C–E♭–G。全部降半音是移调，降低五度则改变另一项关系。',
      ),
      CourseQuestion(
        'Am 的 ♭3 是哪个音？',
        ['C', 'C♭', 'C♯'],
        0,
        'A 的大三度是 C♯，降低半音就是 C。♭3 描述关系，并不要求目标音名一定含 ♭。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '减与增：再检查五度音',
    goal: '比较四类三和弦时，能指出每一次改变的是三度还是五度。',
    reference: '第 13–14 章，书内 42–43、46 页',
    sections: [
      (
        '从小三和弦继续得到减三和弦',
        'Cm 是 C–E♭–G。把纯五度 G 再降半音得到 G♭，成为 Cdim：C–E♭–G♭，公式 1、♭3、♭5。C→E♭ 和 E♭→G♭ 各 3 个半音，是两个小三度。减三和弦不是“每个音都变低”。',
      ),
      (
        '从大三和弦得到增三和弦',
        'C 是 C–E–G。保留根音和大三度，把 G 升半音为 G♯，成为 Caug：C–E–G♯，公式 1、3、♯5。C→E 与 E→G♯ 各 4 个半音，是两个大三度。',
      ),
      (
        '用比较代替四张互不相干的图',
        '先比较 C 与 Cm 的三度，再比较 Cm 与 Cdim 的五度；最后回到 C，比较 C 与 Caug 的五度。增三和弦等距、减三和弦也有对称关系，但当前例子固定根音 C，不在这里重新命名为别的和弦。',
      ),
    ],
    scores: [
      CourseScore(
        '四类三和弦并排核对',
        [for (var q = 0; q < 4; q++) _triad(0, q).voicing],
        'C = C E G；Cm = C E♭ G；Cdim = C E♭ G♭；Caug = C E G♯。小屏可以横向拖动，每次只比较两列。',
      ),
    ],
    tasks: [
      '画：列出四个公式，并分别圈出 ♭3、♭5、♯5。',
      '说：分别解释“大→小”“小→减”“大→增”改了哪一个音。',
      '弹：两两比较相邻示例，边弹边指出移动的弦与品。',
    ],
    questions: [
      CourseQuestion(
        'Cm 变成 Cdim，应改变哪个音？',
        ['C→C♭', 'E♭→E', 'G→G♭'],
        2,
        'Cm 已有小三度。再把纯五度降为减五度，就得到 C–E♭–G♭。',
      ),
      CourseQuestion(
        'Caug 的构成音是什么？',
        ['C–E–G♯', 'C–E♭–G♯', 'C–E–G♭'],
        0,
        '增三和弦仍保留大三度 E；被升高的是五度 G，成为 G♯。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '同一组音：琶音与和弦',
    goal: '看懂同列一起弹、跨列依次弹，并能把一个三和弦拆成逐音练习。',
    reference: '引言；第 13–14 章，书内 41–44 页',
    sections: [
      (
        '先确定弹的是什么',
        '三和弦的构成音决定音的集合；琶音与一起拨响描述的是演奏方式。C、E、G 既可以一个接一个弹，也可以分布在不同弦上一起发声。逐个弹时，坏音和错音更容易被发现。',
      ),
      (
        '把谱与动作对应起来',
        '第一段 TAB 的三个数字竖直对齐，表示一起拨响三根弦。第二段每列只有一个数字，从左往右依次弹 C、E、G、E、C。每次只拨出现数字的那根弦，其他弦留空不是“零品”。',
      ),
      (
        '先定位、再说、最后弹',
        '拿琴前先画出这三个音的位置，再说“三弦五品 C 是根音、二弦五品 E 是三度、一弦三品 G 是五度”。随后才逐个弹出，检查每根弦是否清楚。检查完成后再一起拨响；暂时不追求速度。',
      ),
    ],
    scores: [
      CourseScore('一起拨响', [_triad(0, 0).voicing], '三个数字同一列，表示一个和弦奏法，不是三次依次弹。'),
      CourseScore(
        '把上面的三个音拆开',
        _triad(0, 0).arpeggio,
        '顺序为 C→E→G→E→C。TAB 的音名与品位一一对应，没有播放或计时。',
      ),
    ],
    tasks: [
      '画：不看谱，在六线谱中标出 C、E、G 的这三个位置。',
      '说：按低→中→高顺序说出音名和根音/三度/五度。',
      '弹：逐个检查声音，再一起拨响；有闷音就停下来修正。',
    ],
    questions: [
      CourseQuestion(
        'TAB 中三个数字在同一列，应怎样理解？',
        ['依次弹三个数字', '一起拨响三个对应的音', '任选一个数字弹'],
        1,
        '竖直对齐表示同一时刻的一组音；横向排列的不同列才表示先后顺序。',
      ),
      CourseQuestion(
        '把 C–E–G 拆成琶音后，它的构成音集合变了吗？',
        ['没有，仍是 C、E、G', '变成了三个新的和弦', '必须换成别的音'],
        0,
        '奏法变为逐音，不会自动改变所用的音。先逐音还能更容易检查弦是否按清楚。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '三和弦为何能弹五根弦',
    goal: '区分不同的构成音与重复的音，理解声部是实际安排方式。',
    reference: '第 14 章，书内 44–46 页',
    sections: [
      (
        '数“种类”，再数“声音”',
        '开放 C 和弦从五弦到一弦是 C、E、G、C、E，共有五根弦发声，但去掉同名音的重复，只剩 C、E、G 三类构成音。三和弦的“三”不是限制可弹的弦数。',
      ),
      (
        '什么是声部安排',
        '同一个和弦可以有不同音区、排列与重复，具体安排就是一种声部配置。下面三个音的 C 与五个音的开放 C 都包含根音、三度、五度。练习时应先检查每根弦的音，再判断是否属于当前和弦。',
      ),
      (
        '先保证齐全，再学习省略',
        '这一阶段的三和弦示例都保留三种构成音。不要因为“可以重复”就认为任意音都可以加进去；也不要随意省掉决定大小性质的三度。后续音乐语境可能允许省略或加入其他音，但那需要新的解释。',
      ),
    ],
    scores: [
      CourseScore('同一个 C 的两种安排', [
        _triad(0, 0).voicing,
        beginnerChords['C']!,
      ], '左列：三弦 C、二弦 E、一弦 G；右列：五弦 C、四弦 E、三弦 G、二弦 C、一弦 E。右列六弦不弹。'),
    ],
    tasks: [
      '画：写出开放 C 的五个发声音名，圈出重复出现的 C 与 E。',
      '说：说明“五根弦”和“三种构成音”为什么不矛盾。',
      '弹：从五弦开始逐弦拨响开放 C，再与三音 C 的安排比较。',
    ],
    questions: [
      CourseQuestion(
        'C–E–G–C–E 一共有几种不同的音名？',
        ['五种', '三种', '两种'],
        1,
        '后面的 C 与 E 重复了前面的音名；不同八度仍可以属于同一种和弦角色。',
      ),
      CourseQuestion(
        '开放 C 的六弦应该怎样处理？',
        ['必须弹，因为是六弦吉他', '不弹，按谱只从五弦开始', '必须按三品'],
        1,
        '当前开放 C 示例六弦留空表示不弹。按示例检查范围，不要把空白当空弦 0。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '用最低音认识三个转位',
    goal: '从实际最低音判断原位与转位，同时保留和弦的根音身份。',
    reference: '第 14 章，书内 47 页',
    sections: [
      (
        '先说构成音，再看谁在最低处',
        'C、E、G 的和弦根音是 C。让 C 在最低处叫原位；让 E 在最低处是第一转位；让 G 在最低处是第二转位。转位名称由最低的实际声音决定，不由最高音、最粗弦编号或哪根手指按得最远决定。',
      ),
      (
        '三个声部都弹 C 和弦',
        'C–E–G、E–G–C、G–C–E 依次对应原位、第一转位、第二转位。后两者可标 C/E、C/G：斜线前是和弦名，后是最低音。C/E 的根音仍是 C，不能因为 E 在低处就改叫 E 和弦。',
      ),
      (
        '核对的是音高，不只是弦序',
        '下面使用三根相邻高音弦的上行密集声部。对这一组示例，三弦是最低音所在弦；不过判断转位的根本依据是音高与角色。换成别的弦组或特殊调弦时，应重新核对实际声音。',
      ),
    ],
    scores: [
      CourseScore(
        '原位 → 第一转位 → 第二转位',
        [for (var i = 0; i < 3; i++) _inverted(i)],
        '每列从低到高分别是 C–E–G、E–G–C、G–C–E。音名集合保持不变；需要换把，不要求保持所有手指不动。',
      ),
    ],
    tasks: [
      '画：把 C、E、G 按三种顺序写出，圈出每组的最低音。',
      '说：完整说出“C/E 是 C 大三和弦第一转位，最低音为三度 E”。',
      '弹：逐弦核对每个声部，先弹最低音再一起拨响。',
    ],
    questions: [
      CourseQuestion(
        'C 和弦的最低音是 E，它是哪种转位？',
        ['原位', '第一转位', '第二转位'],
        1,
        'E 是 C 的三度音。三度在最低处，是第一转位；根音仍为 C。',
      ),
      CourseQuestion(
        'C/G 中，G 表示什么？',
        ['新和弦的根音一定是 G', '必须用 G 和弦手型', '实际最低音是 G'],
        2,
        '斜线后标低音；斜线前仍是 C。这个三和弦声部中，G 是五度音，因此是第二转位。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '移调与转位不是一回事',
    goal: '能区分“所有音一起移动”“改变某个音”“重新安排最低音”。',
    reference: '根音型式及第 13–14 章的移调练习',
    sections: [
      (
        '相同关系搬到新的根音',
        'C–E–G 的每个音都升高一个全音，变成 D–F♯–A。三个音的间距仍是 0、4、7，所以仍是大三和弦，但根音从 C 变成 D。这叫移调；根音音程关系没有改变。',
      ),
      (
        '不要混淆三种变化',
        'C→D 是移调，C→Cm 是改变和弦性质，C→C/E 是改变声部与转位。练习时先说清想改变哪一件事，再移动手；如果三个音都变了，但仍称同根音大变小，就要重新检查。',
      ),
      (
        '开放弦不能被遗忘',
        '下例的三个音都按在品上，全部向琴身移动两品即可。开放 C 的 0 品若要整体移调，也必须移动或使用适当横按/变调夹，不能只移动原先按住的几个手指却让空弦原地不动。',
      ),
    ],
    scores: [
      CourseScore('可移动的三音 C → D', [
        _triad(0, 0).voicing,
        _triad(2, 0).voicing,
      ], '三弦 5→7、二弦 5→7、一弦 3→5，三个音都升高两品。公式仍为 1、3、5。'),
    ],
    tasks: [
      '画：在三个箭头旁都写上“+2 品”，再写出新音名。',
      '说：分别说明 C→D、C→Cm、C→C/E 改变了什么。',
      '弹：在三根高音弦上整体移动两品，逐弦核对 D、F♯、A。',
    ],
    questions: [
      CourseQuestion(
        'C–E–G 每个音都升高两品，得到什么？',
        ['C–E♭–G', 'E–G–C', 'D–F♯–A'],
        2,
        '同弦两品是一个全音。C→D、E→F♯、G→A，关系不变而根音改变。',
      ),
      CourseQuestion(
        'C–E–G 变成 E–G–C 属于哪类变化？',
        ['三和弦变七和弦', '转位', '整体移调'],
        1,
        '音名集合没有改变，只调整排列和最低音。这是 C 和弦的第一转位。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '七和弦：在三和弦上加什么',
    goal: '区分大七、属七、小七的三度与七度，并在完整四音声部中找到它们。',
    reference: '第 15–16 章，书内 48–49、51–52 页',
    sections: [
      (
        '七不是七个音',
        '七和弦通常由根音、三度、五度、七度四类音组成。“七”来自加入七度关系，不是要求弹七根弦。先把三和弦构成说清楚，再决定加大七度还是小七度。',
      ),
      (
        '三种最容易混淆的符号',
        'Cmaj7 = C–E–G–B，公式 1、3、5、7；C7 = C–E–G–B♭，公式 1、3、5、♭7；Cm7 = C–E♭–G–B♭，公式 1、♭3、5、♭7。单写 7 通常表示属七，不能把 C7 当作 Cmaj7 的简写。',
      ),
      (
        '构成顺序和实际摆放可以不同',
        '从 C 到 B 是 11 个半音，到 B♭ 是 10 个半音。下面的声部按低到高排列为“根音—五度—七度—三度”，比把四个音挤在一个很低的音区更适合这组吉他指型。排列改变并不会自动改变构成公式。',
      ),
    ],
    scores: [
      CourseScore(
        'Cmaj7 → C7 → Cm7',
        [for (final shape in seventhLessonShapes.take(3)) shape.chord],
        '五弦到二弦：Cmaj7 = C G B E；C7 = C G B♭ E；Cm7 = C G B♭ E♭。六弦与一弦都不弹。先改三弦七度，再改二弦三度。',
      ),
    ],
    tasks: [
      '画：列出 Cmaj7、C7、Cm7，分别圈出三度和七度。',
      '说：解释 C7 为什么有大三度 E，却是小七度 B♭。',
      '弹：仅拨五、四、三、二弦，比较 B→B♭ 与 E→E♭。',
    ],
    questions: [
      CourseQuestion(
        'Cmaj7 变成 C7，应改变哪个音？',
        ['E→E♭', 'B→B♭', 'G→G♭'],
        1,
        '两者都是大三和弦底子。大七度 B 降半音为小七度 B♭，就由 maj7 变成属七 7。',
      ),
      CourseQuestion(
        'Cm7 的构成音是什么？',
        ['C–E–G–B♭', 'C–E♭–G–B', 'C–E♭–G–B♭'],
        2,
        '小三度 E♭ 与小七度 B♭ 都要有；只有其中一个降低，会变成别的性质。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '半减七与减七：别漏掉第七音',
    goal: '知道两者拥有相同的减三和弦基础，但七度不同。',
    reference: '第 15–16 章，书内 50–52 页',
    sections: [
      (
        '先固定减三和弦底子',
        'C–E♭–G♭ 是 C 减三和弦。加入小七度 B♭，得到 Cm7♭5，也叫半减七，公式 1、♭3、♭5、♭7。这个名字提醒你：小七和弦的五度又降低了半音。',
      ),
      (
        '再把七度降低半音',
        '把 B♭ 降半音，在音程拼写中写成 B♭♭，便得到 Cdim7：C–E♭–G♭–B♭♭。公式 1、♭3、♭5、♭♭7；B♭♭ 在吉他上与 A 同音，但写作减七度才说明它在 C 和弦里的角色。',
      ),
      (
        '比较一次，只移动一个声音',
        'Cm7♭5 和 Cdim7 的根音、三度、五度都一样，只有七度不同。下面三弦从三品 B♭ 移到二品 A（理论拼写 B♭♭），其余三根发声弦不动。不要因二者都带“减”，就忽略它们的差别。',
      ),
    ],
    scores: [
      CourseScore(
        '同一减三和弦，加入两种七度',
        [seventhLessonShapes[3].chord, seventhLessonShapes[4].chord],
        'Cm7♭5：C G♭ B♭ E♭；Cdim7：C G♭ B♭♭ E♭。只把三弦三品移到二品；其余发声位置相同。',
      ),
    ],
    tasks: [
      '画：把两种公式并排写下，圈出 ♭7 与 ♭♭7。',
      '说：说明 B♭♭ 为什么能在琴上弹出与 A 相同的声音。',
      '弹：保持五弦、四弦、二弦不动，只切换三弦三品与二品。',
    ],
    questions: [
      CourseQuestion(
        '半减七与减七在本例中主要差在哪里？',
        ['根音不同', '三度不同', '七度不同'],
        2,
        '二者都含 C、E♭、G♭；半减七加 B♭，减七加 B♭♭。',
      ),
      CourseQuestion(
        'Cdim7 的 ♭♭7 在吉他上与哪个音同音？',
        ['A', 'B', 'B♭'],
        0,
        'C 上方大七度是 B，降低两个半音成为 B♭♭，在十二平均律吉他上与 A 同音。',
      ),
    ],
  ),
  ChordCourseLesson(
    title: '把知识带回实际练习',
    goal: '看到和弦名后，能先说明构成，再找位置、核对发声弦，最后练转换。',
    reference: '引言；第 13–16 章的练习方法',
    sections: [
      (
        '先做一张自己的和弦卡',
        '写下名称、公式、构成音，再写每根发声弦的音名。比如 Am：1、♭3、5；A、C、E；开放指法从五弦起是 A、E、A、C、E。这张卡应能说明手型为什么正确。',
      ),
      (
        '把错误分成三种',
        '公式或音名错，要回音程与和弦构成课；音名对但找错弦品，要慢下来逐弦定位；弦品对但闷音，要检查指尖、邻弦接触和靠近品丝的位置。不要把所有问题都归结为“手不够快”。',
      ),
      (
        '一次练一个小单位',
        '下面依次是 C、Am、Em、G。先任选一对慢慢切换，逐弦检查清楚后再连接整段。可以用首页节拍器慢练，但本页不自动播放、不判断弹奏，也不要求一天完成所有课程。未完成自检也可以先读下一课，再回来补练。',
      ),
    ],
    scores: [
      CourseScore(
        '先解释每个和弦，再练转换',
        [
          for (final name in ['C', 'Am', 'Em', 'G']) beginnerChords[name]!,
        ],
        'C = C E G；Am = A C E；Em = E G B；G = G B D。谱里有重复音，逐弦核对后再一起扫。',
      ),
    ],
    tasks: [
      '画：给 C、Am、Em、G 各写名称、公式、构成音，不确定就回相应课程。',
      '说：任选一个，解释最低音、重复音和不弹的弦。',
      '弹：只练一对转换；都清楚后再连接整段，并按问题类型安排复习。',
    ],
    questions: [
      CourseQuestion(
        '音名与公式正确，实际按出的音却不属于和弦，应先检查什么？',
        ['只提高速度', '弦号和品位是否找对', '直接换更难的和弦'],
        1,
        '先把每根弦实际发出的音与构成音核对。位置错与手速慢是不同的问题。',
      ),
      CourseQuestion(
        '开放 Am 弹出 A–E–A–C–E，它为什么仍是小三和弦？',
        ['因为只有三个手指按弦', '因为所有音都一样低', '构成音仍只有 A、C、E，含小三度 C'],
        2,
        '重复的 A、E 不改变三类构成音。决定小三和弦性质的是根音 A、三度 C、五度 E 的关系。',
      ),
    ],
  ),
];
