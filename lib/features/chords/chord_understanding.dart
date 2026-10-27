import 'package:flutter/material.dart';

import 'chord_tab.dart';
import 'chord_theory.dart';

const _topics = [
  (
    '1 · 从根音和音程开始',
    '先分清三个“数字”',
    '根音决定和弦叫什么，音程说明其他音与根音的关系。一个半音是吉他上相邻的一品，两个半音是一个全音。\n\n以 C 为根音：C 到 E 相隔 4 个半音，是大三度；C 到 G 相隔 7 个半音，是纯五度。公式 1、3、5 表示音的角色，不是第 1、3、5 品，也不是手指编号。♭3 表示把大三度降低一个半音，不要求那个音的名字一定带降号。\n\n比如 A 小三和弦的 ♭3 是 C：它比 A 的大三度 C♯ 低一个半音。先说出根音，再从根音数距离，最后核对音名。',
  ),
  (
    '2 · 用三个音搭出和弦',
    '三和弦为什么能弹六根弦？',
    '三和弦由根音、三度音、五度音这三类音组成。性质由它们之间的距离决定；换一种摆法，不一定换了和弦。\n\nC 大三和弦的构成音是 C、E、G。开放 C 和弦从五弦到一弦弹出 C、E、G、C、E：仍然只有这三类音，只是有些音在不同八度重复。三和弦不等于只许弹三根弦。\n\n比较同根音的大、小、减、增三和弦，观察到底是哪一个音升高或降低，而不是一次背四张手型。这里用三根高音弦、每弦一个音，先把三个角色看清楚。',
  ),
  (
    '3 · 先逐个弹，再一起弹',
    '同一组音，两种练法',
    '把构成音按顺序逐个弹出，是琶音；把不同弦上的构成音一起拨响或扫响，是和弦奏法。它们可以使用同一组音、同一个手型。\n\n先对照谱和下方音名，指出根音、三度音、五度音各在哪根弦、哪一品。再从低音到高音逐个弹，边弹边说音名与角色，最后一起拨响，比较它们的关系。\n\n下面的逐音示例按“低—中—高—中—低”排列，所有音都来自当前声部。不要把同列的三个数字当成先后顺序；同列是一起弹，跨列才是依次弹。',
  ),
  (
    '4 · 换最低音，认识转位',
    '用最低音判断，不靠手型猜',
    '声部是构成音在实际音区中的安排。根音在最低处叫原位，三度音在最低处叫第一转位，五度音在最低处叫第二转位。\n\n以 C 大三和弦为例，C–E–G、E–G–C、G–C–E 都含 C、E、G；和弦仍是 C，只是最低音变了。后两个声部也常写作 C/E、C/G，斜线后面是实际低音。\n\n改变根音是移调，改变三度或五度可能改变性质，改变最低音是转位。这三件事要分开观察。增三和弦可以有等音重解释，此处固定所选根音来说明转位。',
  ),
];

class ChordUnderstanding extends StatefulWidget {
  const ChordUnderstanding({super.key});
  @override
  State<ChordUnderstanding> createState() => _ChordUnderstandingState();
}

class _ChordUnderstandingState extends State<ChordUnderstanding> {
  int _topic = 0;
  int _root = 0;
  int _quality = 0;
  int _inversion = 0;
  int? _answer;

  void _change(VoidCallback update) => setState(() {
    update();
    _answer = null;
  });

  Widget _selector(
    String label,
    int value,
    List<String> names,
    ValueChanged<int> change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      key: ValueKey(label),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (var i = 0; i < names.length; i++)
          DropdownMenuItem(value: i, child: Text(names[i])),
      ],
      onChanged: (value) {
        if (value != null) _change(() => change(value));
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final example = TriadExample(
      chordRoots[_root],
      triadQualities[_quality],
      _inversion,
    );
    final shape = example.voicing;
    final style = Theme.of(context).textTheme;
    final topic = _topics[_topic];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('自由探索三和弦', style: style.headlineMedium),
        const SizedBox(height: 8),
        const Text('学习路线：认识音程 → 搭出三和弦 → 逐音与合奏 → 理解转位。先看懂和说清，再拿起吉他核对。'),
        const SizedBox(height: 20),
        _selector('学习主题', _topic, [
          for (final topic in _topics) topic.$1,
        ], (i) => _topic = i),
        Text(topic.$2, style: style.titleLarge),
        const SizedBox(height: 12),
        Text(topic.$3, style: style.bodyLarge?.copyWith(height: 1.6)),
        const SizedBox(height: 24),
        Text('动手构建一个三和弦', style: style.titleLarge),
        const SizedBox(height: 8),
        const Text('先保持根音不变，只切换性质；再保持性质不变，比较三个转位。最后换根音，检查公式是否仍然成立。'),
        const SizedBox(height: 16),
        _selector('根音', _root, [
          for (final root in chordRoots) root.name,
        ], (i) => _root = i),
        _selector('三和弦性质', _quality, [
          for (final quality in triadQualities) quality.name,
        ], (i) => _quality = i),
        _selector('声部与转位', _inversion, inversionNames, (i) => _inversion = i),
        Card.outlined(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${example.name} · ${example.quality.name}',
                  style: style.titleLarge,
                ),
                Text('构成公式：${example.formula}'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Chip(
                        label: Text(
                          '${example.quality.degrees[i]} ${toneRoles[i]} ${example.notes[i]}',
                        ),
                      ),
                  ],
                ),
                Text(example.quality.explanation),
                const SizedBox(height: 8),
                const Text(
                  '音名按音程关系拼写：例如 E♯ 与 F 同音，♯♯ 表示升高两个半音。名字不同不一定需要弹不同的品位。',
                ),
                const SizedBox(height: 12),
                Text(
                  '当前最低音：${example.notes[_inversion]}（${toneRoles[_inversion]}）· ${inversionNames[_inversion]}',
                ),
                if (_inversion > 0)
                  Text('低音标记：${example.name}/${example.notes[_inversion]}'),
                const SizedBox(height: 12),
                const Text(
                  '读 TAB：从上到下是一弦到六弦；数字是品位，0 是空弦，留空的弦不弹。公式里的 1、3、5 是角色，和 TAB 的品位数字含义不同。',
                ),
                const SizedBox(height: 8),
                ChordTab(chords: [shape]),
                const Text('三个数字在同一列：一起拨响这三根弦。其余弦不弹。'),
                const SizedBox(height: 12),
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${3 - i} 弦 ${shape.frets[i + 3]} 品 → ${example.notes[example.toneOrder[i]]} · ${example.quality.degrees[example.toneOrder[i]]}（${toneRoles[example.toneOrder[i]]}）',
                    ),
                  ),
                const Text(
                  '这是高音三根弦上的一种密集声部，不是全部可用指型。TAB 数字是品位，公式数字是音程角色；手指安排可按手型选择。不同转位可能需要换把。',
                ),
              ],
            ),
          ),
        ),
        if (_topic >= 2) ...[
          const SizedBox(height: 20),
          Text('把同一组音拆开弹', style: style.titleLarge),
          const SizedBox(height: 8),
          ChordTab(chords: example.arpeggio),
          const Text(
            '每一列只弹一个音：低 → 中 → 高 → 中 → 低。边弹边说出音名，再回到上面的和弦一起拨响。这里不规定时值，也不自动播放。',
          ),
        ],
        const SizedBox(height: 24),
        Text('先回答，再核对', style: style.titleLarge),
        Text('当前 ${example.name} 的最低音 ${example.notes[_inversion]}，是什么角色？'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < 3; i++)
              OutlinedButton(
                onPressed: () => setState(() => _answer = i),
                child: Text(toneRoles[i]),
              ),
          ],
        ),
        if (_answer != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '${_answer == _inversion ? '答对了' : '再看一下最低音'}：${example.notes[_inversion]} 是${toneRoles[_inversion]}，所以是${inversionNames[_inversion]}。根音仍是 ${example.root.name}。',
              key: const ValueKey('chord-answer'),
            ),
          ),
        const SizedBox(height: 20),
        const Text(
          '练习验收：不看提示说出三个构成音；找到它们的弦与品；逐个弹后一起拨响；解释当前最低音为什么构成这个转位。换一个根音再试一次。',
        ),
        const SizedBox(height: 12),
        const Text('课程第 10–11 课介绍五类常见七和弦；这里的自由探索器仍专用于三和弦。其他弦组与更多把位尚未加入。'),
        const SizedBox(height: 12),
        Text(
          '参考阅读：《吉他指板手册》引言及第 13–14 章（书内第 4–5、41–47 页）。示例在本次页面内保留，退出后清除。',
          style: style.bodySmall,
        ),
      ],
    );
  }
}
