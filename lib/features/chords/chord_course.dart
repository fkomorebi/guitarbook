import 'package:flutter/material.dart';

import 'chord_course_data.dart';
import 'chord_tab.dart';

class ChordCourse extends StatefulWidget {
  const ChordCourse({super.key, this.onNavigate});
  final VoidCallback? onNavigate;
  @override
  State<ChordCourse> createState() => _ChordCourseState();
}

class _ChordCourseState extends State<ChordCourse> {
  int _lesson = 0;
  final _answers = <int, List<int?>>{};
  final _tasks = <int, List<bool>>{};
  final _completed = <int>{};

  void _navigate(int index) {
    setState(() => _lesson = index);
    widget.onNavigate?.call();
  }

  @override
  Widget build(BuildContext context) {
    final lesson = chordCourse[_lesson];
    final answers = _answers.putIfAbsent(
      _lesson,
      () => List.filled(lesson.questions.length, null),
    );
    final tasks = _tasks.putIfAbsent(
      _lesson,
      () => List.filled(lesson.tasks.length, false),
    );
    final ready =
        tasks.every((done) => done) &&
        List.generate(
          answers.length,
          (i) => answers[i] == lesson.questions[i].correct,
        ).every((correct) => correct);
    final type = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('和弦入门课程', style: type.headlineMedium),
        const SizedBox(height: 8),
        const Text('从一个音开始，逐步理解三和弦、转位与常见七和弦。每课先看例子，再画、说、弹，最后核对。'),
        const SizedBox(height: 12),
        Text(
          '已记录自检 ${_completed.length} / ${chordCourse.length} 课',
          key: const ValueKey('course-progress'),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: _completed.length / chordCourse.length,
          semanticsLabel: '已记录课程自检',
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<int>(
          key: ValueKey('course-selector-$_lesson'),
          initialValue: _lesson,
          isExpanded: true,
          itemHeight: null,
          decoration: const InputDecoration(
            labelText: '课程目录',
            border: OutlineInputBorder(),
          ),
          items: [
            for (var i = 0; i < chordCourse.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text('${i + 1}. ${chordCourse[i].title}'),
              ),
          ],
          onChanged: (index) {
            if (index != null) _navigate(index);
          },
        ),
        const SizedBox(height: 20),
        Text('第 ${_lesson + 1} 课 · ${lesson.title}', style: type.titleLarge),
        const SizedBox(height: 12),
        Card.filled(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('学完这一课，你应该能…', style: type.titleSmall),
                const SizedBox(height: 6),
                Text(lesson.goal, style: type.bodyLarge),
              ],
            ),
          ),
        ),
        for (var i = 0; i < lesson.sections.length; i++) ...[
          const SizedBox(height: 20),
          Text('${i + 1}. ${lesson.sections[i].$1}', style: type.titleMedium),
          const SizedBox(height: 8),
          Text(
            lesson.sections[i].$2,
            style: type.bodyLarge?.copyWith(height: 1.65),
          ),
        ],
        const SizedBox(height: 24),
        Text('对照例谱', style: type.titleLarge),
        const SizedBox(height: 8),
        const Text('六条线从上到下是一弦至六弦；数字表示品位，0 是空弦，留空不弹。同列一起弹，从左往右依次练习；这里不规定时值。'),
        for (var i = 0; i < lesson.scores.length; i++) ...[
          const SizedBox(height: 16),
          Text(lesson.scores[i].title, style: type.titleMedium),
          const SizedBox(height: 8),
          ChordTab(
            key: ValueKey('course-score-$_lesson-$i'),
            chords: lesson.scores[i].chords,
          ),
          const SizedBox(height: 8),
          Text(lesson.scores[i].caption, style: type.bodyLarge),
        ],
        const SizedBox(height: 24),
        Text('离开提示，自己做一次', style: type.titleLarge),
        const SizedBox(height: 8),
        const Text('下面是自我检查，不是自动判定。完成一项再勾选；声音不清楚就回去慢练，疼痛时停下休息。'),
        for (var i = 0; i < lesson.tasks.length; i++)
          CheckboxListTile(
            key: ValueKey('course-task-$i'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(lesson.tasks[i]),
            value: tasks[i],
            onChanged: (value) => setState(() {
              tasks[i] = value ?? false;
              if (!tasks[i]) _completed.remove(_lesson);
            }),
          ),
        const SizedBox(height: 20),
        Text('核对理解', style: type.titleLarge),
        const Text('先选答案，再看解析。选错时根据解释重做，不以阅读次数或速度衡量掌握程度。'),
        for (var q = 0; q < lesson.questions.length; q++)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Card.outlined(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${q + 1}. ${lesson.questions[q].prompt}',
                      style: type.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (var a = 0; a < lesson.questions[q].choices.length; a++)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton(
                          key: ValueKey('course-answer-$q-$a'),
                          style: OutlinedButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            backgroundColor: answers[q] == a
                                ? colors.secondaryContainer
                                : null,
                            foregroundColor: answers[q] == a
                                ? colors.onSecondaryContainer
                                : null,
                          ),
                          onPressed: () => setState(() {
                            answers[q] = a;
                            if (a != lesson.questions[q].correct) {
                              _completed.remove(_lesson);
                            }
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(lesson.questions[q].choices[a]),
                          ),
                        ),
                      ),
                    if (answers[q] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '${answers[q] == lesson.questions[q].correct ? '答对了' : '再想一想'}。正确答案：${lesson.questions[q].choices[lesson.questions[q].correct]}。\n${lesson.questions[q].reason}',
                          key: ValueKey('course-explanation-$q'),
                          style: type.bodyLarge,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          key: const ValueKey('course-complete'),
          onPressed: ready
              ? () => setState(() => _completed.add(_lesson))
              : null,
          child: Text(_completed.contains(_lesson) ? '本课已记录自检' : '记录本课自检'),
        ),
        const SizedBox(height: 8),
        Text(
          ready
              ? '自检通过仍需在琴上反复巩固，记录不代表自动评价演奏水平。'
              : '完成三个练习任务，并答对两道核对题后，可以记录本课自检。',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() {
              _answers.remove(_lesson);
              _tasks.remove(_lesson);
              _completed.remove(_lesson);
            }),
            child: const Text('重新练本课'),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _lesson > 0 ? () => _navigate(_lesson - 1) : null,
              child: const Text('上一课'),
            ),
            OutlinedButton(
              onPressed: _lesson + 1 < chordCourse.length
                  ? () => _navigate(_lesson + 1)
                  : null,
              child: const Text('下一课'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('可先阅读下一课；没有做完自检的课不会自动计入进度。课程状态仅本次页面有效，退出后清除。'),
        const SizedBox(height: 16),
        Text('参考阅读：《吉他指板手册》${lesson.reference}。', style: type.bodySmall),
      ],
    );
  }
}
