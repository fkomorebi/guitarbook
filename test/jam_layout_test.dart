import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drums_page.dart';
import 'package:guitarbook/features/looper/looper_controller.dart';

import 'drums_page_test.dart' show FakeDrumAudio;
import 'effects_page_test.dart' show FakeEffects;
import 'looper_test.dart' show FakeInput, FakeOutput;

class UnsupportedEffects extends FakeEffects {
  @override
  bool get supported => false;
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

void main() {
  testWidgets('all tools share a page and their volumes are independent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final effects = FakeEffects();
    final audio = FakeDrumAudio();
    final c = LooperController(FakeInput(), FakeOutput.new);
    await tester.pumpWidget(
      MaterialApp(
        home: DrumsPage(
          audio: audio,
          effectsBackend: effects,
          looperController: c,
        ),
      ),
    );
    await tester.pump();
    expect(effects.calls.first, 'probe');
    expect(effects.running, isFalse);
    expect(find.byKey(const ValueKey('drum-deck')), findsOneWidget);
    expect(find.byKey(const ValueKey('looper-deck')), findsOneWidget);
    expect(find.byKey(const ValueKey('effects-board')), findsOneWidget);
    await reveal(tester, find.text('开始伴奏'));
    await tester.tap(find.text('开始伴奏'));
    await tester.pump();
    final pattern = audio.pattern;
    final drumVolume = find.byKey(const ValueKey('drum-volume'));
    await reveal(tester, drumVolume);
    await tester.drag(drumVolume, const Offset(-90, 0));
    await tester.pump();
    final drumGain = audio.gain;
    expect(drumGain, lessThan(1));
    expect(audio.playing, isTrue);
    expect(audio.pattern, same(pattern));
    expect(c.playbackGain, 1);
    expect(effects.gain, 0.5);
    final loopVolume = find.byKey(const ValueKey('loop-volume'));
    await reveal(tester, loopVolume);
    await tester.tap(loopVolume);
    await tester.pump();
    expect(c.playbackGain, greaterThan(1));
    expect(audio.gain, drumGain);
    expect(effects.gain, 0.5);
    final effectsVolume = find.byKey(const ValueKey('effects-volume'));
    await reveal(tester, effectsVolume);
    await tester.drag(effectsVolume, const Offset(70, 0));
    await tester.pump();
    expect(effects.gain, greaterThan(0.5));
    expect(audio.gain, drumGain);
    expect(audio.playing, isTrue);
    expect(c.playbackGain, greaterThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(effects.released, isTrue);
    c.dispose();
  });

  testWidgets('device detection failure can recover without monitoring', (
    tester,
  ) async {
    final effects = FakeEffects()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: DrumsPage(audio: FakeDrumAudio(), effectsBackend: effects),
      ),
    );
    await tester.pump();
    expect(find.textContaining('测试设备中断'), findsOneWidget);
    effects.fail = false;
    await reveal(tester, find.text('重新检测'));
    await tester.tap(find.text('重新检测'));
    await tester.pump();
    expect(find.textContaining('检测通过'), findsOneWidget);
    expect(effects.running, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resizing keeps recording, monitoring and drum volume', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final effects = FakeEffects();
    final audio = FakeDrumAudio();
    final c = LooperController(FakeInput(), FakeOutput.new);
    await tester.pumpWidget(
      MaterialApp(
        home: DrumsPage(
          audio: audio,
          effectsBackend: effects,
          looperController: c,
        ),
      ),
    );
    await tester.pump();
    await reveal(tester, find.text('开始伴奏'));
    await tester.tap(find.text('开始伴奏'));
    await tester.pump();
    tester.widget<Slider>(find.byKey(const ValueKey('drum-volume'))).onChanged!(
      0.4,
    );
    c.mainPedal();
    await tester.pump();
    await reveal(tester, find.text('开始监听'));
    await tester.tap(find.text('开始监听'));
    await tester.pump();
    tester.view.physicalSize = const Size(390, 720);
    await tester.pump();
    expect(c.recording, isTrue);
    expect(effects.running, isTrue);
    expect(audio.playing, isTrue);
    expect(audio.gain, 0.4);
    expect(effects.calls.where((c) => c == 'probe'), hasLength(1));
    expect(effects.calls.where((c) => c == 'start'), hasLength(1));
    expect(find.byTooltip('音频输入正在使用'), findsOneWidget);
    tester.view.physicalSize = const Size(1280, 720);
    await tester.pump();
    expect(c.recording, isTrue);
    expect(tester.takeException(), isNull);
    c.stop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'all three tools remain reachable on small screens and large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [
        const Size(1280, 600),
        const Size(1024, 600),
        const Size(390, 720),
        const Size(844, 390),
        const Size(320, 568),
      ]) {
        tester.view.physicalSize = size;
        final effects = UnsupportedEffects();
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(size.width == 320 ? 2 : 1),
              ),
              child: DrumsPage(audio: FakeDrumAudio(), effectsBackend: effects),
            ),
          ),
        );
        await tester.pump();
        for (final key in ['drum-volume', 'loop-volume', 'effects-volume']) {
          final control = find.byKey(ValueKey(key));
          await reveal(tester, control);
          expect(
            control.hitTestable(),
            findsOneWidget,
            reason: '$key at $size',
          );
        }
        expect(
          find.text('此功能支持 Android、iOS、Linux 和 Windows；当前平台暂不支持。'),
          findsOneWidget,
        );
        expect(effects.calls, isEmpty);
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('phone drum paging and swing survive resize with recording', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = LooperController(FakeInput(), FakeOutput.new);
    await tester.pumpWidget(
      MaterialApp(
        home: DrumsPage(
          audio: FakeDrumAudio(),
          effectsBackend: UnsupportedEffects(),
          looperController: c,
        ),
      ),
    );
    await tester.tap(find.text('摇摆 0%'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Slider),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(390, 720);
    await tester.pump();
    expect(find.text('摇摆 30%'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('drum-page-3')));
    await tester.tap(find.byKey(const ValueKey('drum-page-3')));
    await tester.pump();
    expect(find.bySemanticsLabel('底鼓 第 16 步'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('loop-main')));
    await tester.tap(find.byKey(const ValueKey('loop-main')));
    await tester.pump();
    expect(c.recording, isTrue);
    expect(tester.takeException(), isNull);
    c.stop();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'settings dialog learns keys without recording from ordinary shortcuts',
    (tester) async {
      final c = LooperController(FakeInput(), FakeOutput.new);
      await tester.pumpWidget(
        MaterialApp(
          home: DrumsPage(
            audio: FakeDrumAudio(),
            effectsBackend: UnsupportedEffects(),
            looperController: c,
          ),
        ),
      );
      await reveal(tester, find.byTooltip('踏板绑定与录音设置'));
      await tester.tap(find.byTooltip('踏板绑定与录音设置'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
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
      c.stop();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
