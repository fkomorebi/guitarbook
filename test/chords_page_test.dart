import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/app/guitarbook_app.dart';
import 'package:guitarbook/features/chords/chords_page.dart';
import 'package:guitarbook/features/chords/chord_tab.dart';
import 'package:guitarbook/features/chords/chord_lesson.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('ScoreSerif');
    font.addFont(rootBundle.load('assets/fonts/NotoSerif-Regular.ttf'));
    await font.load();
  });

  testWidgets('首页进入，练习循环、自评和阶段重置', (tester) async {
    await tester.pumpWidget(const GuitarbookApp());
    await tester.ensureVisible(find.text('和弦练习'));
    await tester.tap(find.text('和弦练习'));
    await tester.pumpAndSettle();
    expect(find.text('和弦入门课程'), findsOneWidget);
    await tester.tap(find.text('按弦与转换'));
    await tester.pumpAndSettle();
    expect(find.text('现在练 Em'), findsOneWidget);
    expect(find.text('Em 的构成：E · G · B（1 · ♭3 · 5）'), findsOneWidget);
    for (var round = 0; round < 3; round++) {
      await tester.ensureVisible(find.text('按清楚了，练下一个'));
      await tester.tap(find.text('按清楚了，练下一个'));
      await tester.pumpAndSettle();
      expect(find.text('现在练 Am'), findsOneWidget);
      await tester.ensureVisible(find.text('本轮清楚，完成一轮'));
      await tester.tap(find.text('本轮清楚，完成一轮'));
      await tester.pumpAndSettle();
    }
    expect(find.text('自评完成 3 轮'), findsOneWidget);
    tester
        .widget<DropdownButtonFormField<int>>(
          find.byType(DropdownButtonFormField<int>),
        )
        .onChanged!(2);
    await tester.pumpAndSettle();
    expect(find.text('现在练 G'), findsOneWidget);
    expect(find.text('自评完成 0 轮'), findsOneWidget);
    expect(find.text('6 弦：3 品 · 2 指'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('所有和弦 TAB 上一弦下六弦，数字是品位且跳过不弹的弦', (tester) async {
    for (final chord in beginnerChords.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChordTab(chords: [chord])),
        ),
      );
      var previousY = double.negativeInfinity;
      for (var string = 1; string <= 6; string++) {
        final cell = find.byKey(ValueKey('tab-0-string-$string'));
        final fret = chord.frets[6 - string];
        if (fret < 0) {
          expect(cell, findsNothing);
        } else {
          expect(
            find.descendant(of: cell, matching: find.text('$fret')),
            findsOneWidget,
          );
          final y = tester.getCenter(cell).dy;
          expect(y, greaterThan(previousY));
          previousY = y;
        }
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('弦线连续贯穿相邻和弦且普通字号弦距紧凑', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChordTab(
            chords: [beginnerChords['Em']!, beginnerChords['Am']!],
          ),
        ),
      ),
    );
    for (var string = 1; string <= 6; string++) {
      final first = tester.getRect(find.byKey(ValueKey('tab-line-0-$string')));
      final second = tester.getRect(find.byKey(ValueKey('tab-line-1-$string')));
      expect(first.right, closeTo(second.left, 0.01));
      expect(first.top, second.top);
      expect(first.width, greaterThan(100));
    }
    final top = tester.getCenter(find.byKey(const ValueKey('tab-0-string-1')));
    final bottom = tester.getCenter(
      find.byKey(const ValueKey('tab-0-string-6')),
    );
    expect(bottom.dy - top.dy, closeTo(65, 0.01));
    expect(find.byKey(const ValueKey('tab-barline-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-barline-1')), findsOneWidget);
    expect(find.text('T\nA\nB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击 TAB 更新目标但不增加轮数，前进后保持当前列可见', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: ChordsPage()));
    await tester.tap(find.text('按弦与转换'));
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButtonFormField<int>>(
          find.byType(DropdownButtonFormField<int>),
        )
        .onChanged!(3);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(ChordTab));
    await tester.tap(find.byKey(const ValueKey('tab-column-1')));
    await tester.pumpAndSettle();
    expect(find.text('现在练 Am'), findsOneWidget);
    expect(find.text('自评完成 0 轮'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(find.text('按清楚了，练下一个'));
      await tester.tap(find.text('按清楚了，练下一个'));
      await tester.pumpAndSettle();
    }
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('chord-tab-scroll')),
    );
    expect(scroll.controller!.offset, greaterThan(0));
    expect(
      tester
          .widget<Semantics>(find.byKey(const ValueKey('tab-column-3')))
          .properties
          .selected,
      isTrue,
    );
    await tester.ensureVisible(find.text('本轮清楚，完成一轮'));
    await tester.tap(find.text('本轮清楚，完成一轮'));
    await tester.pumpAndSettle();
    expect(scroll.controller!.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部阶段在窄屏双倍字号深色主题下可阅读', (tester) async {
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
    await tester.tap(find.text('按弦与转换'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .onChanged!(i);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(ChordTab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.ensureVisible(find.text('先看这里 · 和弦与 TAB 六线谱'));
    await tester.tap(find.text('先看这里 · 和弦与 TAB 六线谱'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最粗的是六弦'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
