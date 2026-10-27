import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/chords/chord_course_data.dart';
import 'package:guitarbook/features/chords/chord_theory.dart';
import 'package:guitarbook/features/chords/chords_page.dart';
import 'package:guitarbook/features/chords/chord_tab.dart';

void selectLesson(WidgetTester tester, int current, int next) {
  tester
      .widget<DropdownButtonFormField<int>>(
        find.byKey(ValueKey('course-selector-$current')),
      )
      .onChanged!(next);
}

Future<void> press(WidgetTester tester, Finder button) async {
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('ScoreSerif');
    loader.addFont(rootBundle.load('assets/fonts/NotoSerif-Regular.ttf'));
    await loader.load();
  });

  test('12课均包含目标讲解例谱任务与核对题，TAB 数据可演奏', () {
    expect(chordCourse, hasLength(12));
    expect(chordCourse.map((lesson) => lesson.title).toSet(), hasLength(12));
    for (final lesson in chordCourse) {
      expect(lesson.goal, isNotEmpty);
      expect(lesson.sections, hasLength(3));
      expect(lesson.tasks, hasLength(3));
      expect(lesson.questions, hasLength(2));
      expect(lesson.reference, isNotEmpty);
      for (final question in lesson.questions) {
        expect(
          question.correct,
          inInclusiveRange(0, question.choices.length - 1),
        );
        expect(question.reason, isNotEmpty);
        expect(question.choices.toSet().length, question.choices.length);
      }
      for (final score in lesson.scores) {
        expect(score.chords, isNotEmpty);
        expect(score.caption, isNotEmpty);
        for (final chord in score.chords) {
          expect(chord.frets, hasLength(6));
          expect(chord.frets, everyElement(inInclusiveRange(-1, 22)));
        }
      }
    }
  });

  test('五类七和弦声部完整，实际音高按根音五度七度三度排列', () {
    expect(seventhLessonShapes, hasLength(5));
    for (final shape in seventhLessonShapes) {
      expect(shape.frets[0], -1);
      expect(shape.frets[5], -1);
      final pitches = [
        for (var i = 1; i <= 4; i++) guitarOpenMidi[i] + shape.frets[i],
      ];
      expect(pitches.toSet(), hasLength(4));
      expect(pitches.map((p) => p % 12).toSet(), shape.intervals.toSet());
      for (var i = 0; i < 4; i++) {
        expect(pitches[i] % 12, shape.intervals[[0, 2, 3, 1][i]]);
        if (i > 0) expect(pitches[i], greaterThan(pitches[i - 1]));
      }
    }
    expect(seventhLessonShapes.last.notes.last, 'B♭♭');
    expect(seventhLessonShapes.last.intervals.last, 9);
  });

  testWidgets('作答和练习共同决定自检，改错重练会清除记录，跨课模式保留状态', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChordsPage()));
    expect(find.text('和弦入门课程'), findsOneWidget);
    expect(find.text('已记录自检 0 / 12 课'), findsOneWidget);
    final complete = find.byKey(const ValueKey('course-complete'));
    expect(tester.widget<FilledButton>(complete).onPressed, isNull);
    await press(tester, find.byKey(const ValueKey('course-answer-0-1')));
    expect(find.textContaining('再想一想。正确答案：一个半音'), findsOneWidget);
    for (var q = 0; q < 2; q++) {
      await press(
        tester,
        find.byKey(
          ValueKey('course-answer-$q-${chordCourse[0].questions[q].correct}'),
        ),
      );
    }
    expect(tester.widget<FilledButton>(complete).onPressed, isNull);
    for (var t = 0; t < 3; t++) {
      await press(tester, find.byKey(ValueKey('course-task-$t')));
    }
    await press(tester, complete);
    expect(find.text('已记录自检 1 / 12 课'), findsOneWidget);
    await press(tester, find.text('下一课'));
    expect(find.text('第 2 课 · 音程：先数度数，再辨性质'), findsOneWidget);
    expect(find.text('已记录自检 1 / 12 课'), findsOneWidget);
    selectLesson(tester, 1, 0);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('course-task-0')))
          .value,
      isTrue,
    );
    await press(tester, find.text('自由探索'));
    await press(tester, find.text('理解和弦'));
    expect(find.text('已记录自检 1 / 12 课'), findsOneWidget);
    await press(tester, find.byKey(const ValueKey('course-answer-0-2')));
    expect(find.text('已记录自检 0 / 12 课'), findsOneWidget);
    await press(tester, find.byKey(const ValueKey('course-answer-0-0')));
    await press(tester, complete);
    await press(tester, find.byKey(const ValueKey('course-task-0')));
    expect(find.text('已记录自检 0 / 12 课'), findsOneWidget);
    await press(tester, find.text('重新练本课'));
    expect(find.byKey(const ValueKey('course-explanation-0')), findsNothing);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('course-task-1')))
          .value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('12课小屏双倍字号深色主题的讲解例谱与核对题无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: ChordsPage(),
        ),
      ),
    );
    var current = 0;
    for (var i = 0; i < chordCourse.length; i++) {
      selectLesson(tester, current, i);
      current = i;
      await tester.pumpAndSettle();
      expect(
        find.text('第 ${i + 1} 课 · ${chordCourse[i].title}'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byType(ChordTab).first);
      await tester.pumpAndSettle();
      await press(tester, find.byKey(const ValueKey('course-answer-1-0')));
      expect(tester.takeException(), isNull);
      expect(find.text('已记录自检 0 / 12 课'), findsOneWidget);
    }
  });
}
