import 'package:flutter/material.dart';

import 'chord_lesson.dart';
import 'chord_course.dart';
import 'chord_tab.dart';
import 'chord_theory.dart';
import 'chord_understanding.dart';

class ChordsPage extends StatefulWidget {
  const ChordsPage({super.key});

  @override
  State<ChordsPage> createState() => _ChordsPageState();
}

class _ChordsPageState extends State<ChordsPage> {
  int _mode = 0;
  final _pageScroll = ScrollController();

  void _top() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageScroll.hasClients) _pageScroll.jumpTo(0);
    });
  }

  void _switch(int mode) {
    setState(() => _mode = mode);
    _top();
  }

  @override
  void dispose() {
    _pageScroll.dispose();
    super.dispose();
  }

  int _lesson = 0;
  int _position = 0;
  int _rounds = 0;

  @override
  Widget build(BuildContext context) {
    final lesson = chordLessons[_lesson];
    final chord = beginnerChords[lesson.chords[_position]]!;
    final next = lesson.chords[(_position + 1) % lesson.chords.length];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('和弦练习')),
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _pageScroll,
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('理解和弦'),
                        selected: _mode == 0,
                        onSelected: (_) => _switch(0),
                      ),
                      ChoiceChip(
                        label: const Text('自由探索'),
                        selected: _mode == 1,
                        onSelected: (_) => _switch(1),
                      ),
                      ChoiceChip(
                        label: const Text('按弦与转换'),
                        selected: _mode == 2,
                        onSelected: (_) => _switch(2),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Visibility(
                    visible: _mode == 0,
                    maintainState: true,
                    child: ChordCourse(onNavigate: _top),
                  ),
                  Visibility(
                    visible: _mode == 1,
                    maintainState: true,
                    child: const ChordUnderstanding(),
                  ),
                  if (_mode == 2) ...[
                    Text('从第一个和弦开始', style: theme.textTheme.headlineMedium),
                    const Text('不用先懂乐理。先把每根要弹的弦按清楚，再慢慢学会切换。'),
                    const SizedBox(height: 12),
                    const ExpansionTile(
                      title: Text('先看这里 · 和弦与 TAB 六线谱'),
                      children: [
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '和弦是几个音一起发声。Em、Am 中的 m 表示小和弦；C、G、D、E 是大和弦。\n\n最粗的是六弦，最细的是一弦。品是金属品丝之间的格子，从琴头起数。TAB 六条横线从上到下是一弦到六弦，左侧竖排 TAB 是六线谱谱号。\n\n谱上数字表示按第几品，0 表示空弦，没有数字的弦不弹。同一列数字一起弹，从左往右练；竖线区分和弦练习格，末尾双线表示本轮结束；这里不标拍号和时值，按自己的速度练习。点击和弦列可以切换当前练习。\n\n下方文字里的“指”才是手指编号：1 食指、2 中指、3 无名指、4 小指。以下按左手按弦、右手拨弦说明。',
                          ),
                        ),
                      ],
                    ),
                    const ExpansionTile(
                      title: Text('每天约 10 分钟怎么练'),
                      children: [
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '1 分钟：先用首页调音器调好琴。\n3 分钟：看图摆指，松开后重新摆好。\n3 分钟：从最粗的可弹弦起逐弦拨响，检查是否清楚。\n3 分钟：按当前任务慢慢换和弦。\n\n指尖立起，按在靠近品丝但不压住品丝的位置，避免碰到邻弦。声音闷时先逐弦找原因，不要一味用力。疼痛时停下休息。阶段可以重复多天，不必赶进度。',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      initialValue: _lesson,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '选择练习阶段',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (var i = 0; i < chordLessons.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(chordLessons[i].title),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _lesson = value;
                          _position = 0;
                          _rounds = 0;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      lesson.chords.join(' → '),
                      style: theme.textTheme.titleLarge,
                    ),
                    Text(lesson.tip),
                    const SizedBox(height: 12),
                    Card.filled(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '现在练 ${chord.name}',
                              style: theme.textTheme.headlineMedium,
                            ),
                            Text(
                              '第 ${_position + 1} / ${lesson.chords.length} 步 · 下一个 $next',
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${chord.name} 的构成：${openChordTheory(chord).notes.join(' · ')}（${openChordTheory(chord).formula}）',
                            ),
                            const Text('下面同一音名可能在不同八度重复，三和弦不等于只能弹三根弦。'),
                            for (var i = 0; i < 6; i++)
                              Text(openStringRole(chord, i)),
                            const SizedBox(height: 16),
                            ChordTab(
                              chords: [
                                for (final name in lesson.chords)
                                  beginnerChords[name]!,
                              ],
                              selectedIndex: _position,
                              onSelected: (index) =>
                                  setState(() => _position = index),
                            ),
                            const Text('TAB 数字 = 品位 · 0 = 空弦 · 留空 = 不弹'),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              children: [
                                for (var i = 0; i < 6; i++)
                                  Text(chord.instruction(i)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Text('先逐弦检查，再扫一次。每根要弹的弦都清楚，才继续；不清楚就留在这里重练。'),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: () => setState(() {
                                _position++;
                                if (_position == lesson.chords.length) {
                                  _position = 0;
                                  _rounds++;
                                }
                              }),
                              child: Text(
                                _position == lesson.chords.length - 1
                                    ? '本轮清楚，完成一轮'
                                    : '按清楚了，练下一个',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('自评完成 $_rounds 轮', style: theme.textTheme.titleLarge),
                    Text(
                      _rounds >= 3
                          ? '已完成三轮练习！如果能不看图慢慢换好，可以选择下一阶段；也可以继续巩固。'
                          : '小目标：连续完成 3 轮，每个和弦逐弦清楚、转换时能找到位置。',
                    ),
                    const Text('计数由你自己确认，不代表自动评分。中途失误可重新计数。'),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _position = 0;
                          _rounds = 0;
                        }),
                        child: const Text('重新练这一阶段'),
                      ),
                    ),
                    const Text('练习进度仅在本页保留，退出后清除。无需麦克风或联网。'),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
