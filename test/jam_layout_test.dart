import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drums_page.dart';
import 'package:guitarbook/features/looper/looper_controller.dart';

import 'drums_page_test.dart' show FakeDrumAudio;
import 'looper_test.dart' show FakeInput, FakeOutput;

void main() {
  testWidgets(
    'landscape swing edits survive portrait reflow and looper controls show current action',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final input = FakeInput();
      final c = LooperController(input, FakeOutput.new);
      await tester.pumpWidget(
        MaterialApp(
          home: DrumsPage(audio: FakeDrumAudio(), looperController: c),
        ),
      );
      await tester.tap(find.text('摇摆 0%'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Slider));
      await tester.pump();
      expect(find.text('摇摆 30%'), findsNWidgets(2));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(390, 720);
      await tester.pump();
      expect(find.text('摇摆 30%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('jam-tab-looper')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '恢复循环'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('loop-main')));
      await tester.pump();
      expect(find.text('停止循环'), findsOneWidget);
      expect(find.text('Looper · 录音中'), findsOneWidget);
      input.emit(24000);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('loop-main')));
      await tester.pump();
      expect(find.text('Looper · 循环中'), findsOneWidget);
      await tester.tap(find.text('停止循环'));
      await tester.pump();
      expect(find.widgetWithText(OutlinedButton, '恢复循环'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '恢复循环'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump();
    },
  );

  testWidgets('active status labels fit narrow double-text layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = LooperController(FakeInput(), FakeOutput.new);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: DrumsPage(audio: FakeDrumAudio(), looperController: c),
        ),
      ),
    );
    c.mainPedal();
    await tester.pump();
    expect(find.text('Looper · 录音中'), findsOneWidget);
    expect(tester.takeException(), isNull);
    c.stop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump();
  });

  testWidgets(
    'compact desktop, short phone and landscape keep controls on one screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [
        const Size(1280, 600),
        const Size(1024, 600),
        const Size(390, 720),
        const Size(844, 390),
      ]) {
        tester.view.physicalSize = size;
        final c = LooperController(FakeInput(), FakeOutput.new);
        await tester.pumpWidget(
          MaterialApp(
            home: DrumsPage(audio: FakeDrumAudio(), looperController: c),
          ),
        );
        await tester.pump();
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('jam-workspace-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scroll.position.maxScrollExtent, 0, reason: 'drums at $size');
        expect(find.text('开始伴奏').hitTestable(), findsOneWidget);
        await tester.tap(find.text('开始伴奏'));
        await tester.pump();
        expect(
          scroll.position.maxScrollExtent,
          0,
          reason: 'playing drums at $size',
        );
        c.mainPedal();
        await tester.pump();
        expect(
          scroll.position.maxScrollExtent,
          0,
          reason: 'recording with drums at $size',
        );
        if (size.width < 1050) {
          await tester.tap(find.byKey(const ValueKey('jam-tab-looper')));
          await tester.pump();
        }
        expect(scroll.position.maxScrollExtent, 0, reason: 'looper at $size');
        expect(
          find.byKey(const ValueKey('loop-main')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'desktop workspace shows both decks and every step without scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: DrumsPage(audio: FakeDrumAudio())),
      );
      expect(
        find.byKey(const ValueKey('loop-main')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('开始伴奏').hitTestable(), findsOneWidget);
      expect(find.bySemanticsLabel('底鼓 第 16 步').hitTestable(), findsOneWidget);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('jam-workspace-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.maxScrollExtent, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'phone pages drum beats without horizontal scrolling and keeps loop across tabs and resize',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = LooperController(FakeInput(), FakeOutput.new);
      await tester.pumpWidget(
        MaterialApp(
          home: DrumsPage(audio: FakeDrumAudio(), looperController: c),
        ),
      );
      final workspace = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('jam-workspace-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(workspace.position.maxScrollExtent, 0);
      await tester.tap(find.byKey(const ValueKey('drum-page-3')));
      await tester.pump();
      expect(find.bySemanticsLabel('底鼓 第 16 步').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Looper'));
      await tester.pump();
      expect(workspace.position.maxScrollExtent, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.recording, isTrue);
      await tester.tap(find.text('鼓机'));
      await tester.pump();
      expect(c.recording, isTrue);
      expect(find.byTooltip('麦克风采集中，非录音时丢弃输入'), findsOneWidget);
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pump();
      expect(c.recording, isTrue);
      expect(
        find.byKey(const ValueKey('loop-main')).hitTestable(),
        findsOneWidget,
      );
      c.stop();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'settings dialog learns keys while protecting recording from ordinary shortcuts',
    (tester) async {
      final c = LooperController(FakeInput(), FakeOutput.new);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DrumsPage(audio: FakeDrumAudio(), looperController: c),
        ),
      );
      await tester.tap(find.byTooltip('踏板绑定与录音设置'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.recording, isFalse);
      await tester.tap(find.text('绑定键盘：SPACE'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(find.text('绑定键盘：Q'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(c.recording, isTrue);
      expect(tester.takeException(), isNull);
      c.stop();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump();
    },
  );
}
