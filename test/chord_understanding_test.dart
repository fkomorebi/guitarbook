import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/chords/chords_page.dart';
import 'package:guitarbook/features/chords/chord_tab.dart';

void change(WidgetTester tester, String key, int value) {
  tester
      .widget<DropdownButtonFormField<int>>(find.byKey(ValueKey(key)))
      .onChanged!(value);
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('ScoreSerif');
    loader.addFont(rootBundle.load('assets/fonts/NotoSerif-Regular.ttf'));
    await loader.load();
  });
  testWidgets('默认概念教学，构成音声部与自测随选择更新', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChordsPage()));
    expect(find.text('和弦入门课程'), findsOneWidget);
    await tester.tap(find.text('自由探索'));
    await tester.pumpAndSettle();
    expect(find.text('自由探索三和弦'), findsOneWidget);
    expect(find.text('构成公式：1 · 3 · 5'), findsOneWidget);
    change(tester, '根音', 9);
    change(tester, '三和弦性质', 1);
    change(tester, '声部与转位', 1);
    change(tester, '学习主题', 3);
    await tester.pumpAndSettle();
    expect(find.text('Am · 小三和弦'), findsOneWidget);
    expect(find.text('当前最低音：C（三度音）· 第一转位'), findsOneWidget);
    expect(find.text('低音标记：Am/C'), findsOneWidget);
    expect(find.byType(ChordTab), findsNWidgets(2));
    final answer = find.widgetWithText(OutlinedButton, '根音');
    await tester.ensureVisible(answer);
    await tester.tap(answer);
    await tester.pumpAndSettle();
    expect(find.textContaining('再看一下最低音：C 是三度音'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '三度音'));
    await tester.pumpAndSettle();
    expect(find.textContaining('答对了：C 是三度音'), findsOneWidget);
    change(tester, '声部与转位', 2);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chord-answer')), findsNothing);
    expect(find.text('当前最低音：E（五度音）· 第二转位'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('所有主题与性质在窄屏双倍字号深色下可读', (tester) async {
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
    await tester.tap(find.text('自由探索'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      change(tester, '学习主题', i);
      change(tester, '三和弦性质', i);
      change(tester, '根音', 6);
      change(tester, '声部与转位', i % 3);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(ChordTab).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    final answer = find.widgetWithText(OutlinedButton, '五度音');
    await tester.ensureVisible(answer);
    await tester.tap(answer);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chord-answer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
