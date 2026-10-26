import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/app/guitarbook_app.dart';

void main() {
  testWidgets('首页在窄屏和宽屏显示调音器入口', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final size in [const Size(320, 568), const Size(1440, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const GuitarbookApp());
      expect(find.text('吉他宝典'), findsOneWidget);
      expect(find.text('吉他调音器'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('调音器可进入并选择琴弦', (tester) async {
    await tester.pumpWidget(const GuitarbookApp());
    await tester.tap(find.text('吉他调音器'));
    await tester.pumpAndSettle();
    expect(find.text('开始调音'), findsOneWidget);
    expect(find.text('准音区 ±5'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.text('已调准'), findsNothing);
    await tester.tap(find.text('5 弦 A2').first);
    await tester.pump();
    expect(find.text('目标 110.00 Hz'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('跟随系统深色主题且大字号小窗口可滚动', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const GuitarbookApp());
    final context = tester.element(find.byType(Scaffold));
    expect(Theme.of(context).brightness, Brightness.dark);
    await tester.scrollUntilVisible(find.text('吉他调音器'), 100);
    await tester.tap(find.text('吉他调音器'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('准音区 ±5'), 100);
    expect(tester.takeException(), isNull);
  });
}
