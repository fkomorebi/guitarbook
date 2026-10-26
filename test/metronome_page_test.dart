import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/metronome/metronome_page.dart';

import 'metronome_controller_test.dart' show FakeMetronomeAudio;

void main() {
  testWidgets('视觉节拍启动、调速重置及后台停止', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: MetronomePage(audio: FakeMetronomeAudio())),
    );
    await tester.tap(find.widgetWithText(SwitchListTile, '播放声音'));
    await tester.tap(find.text('开始节拍'));
    await tester.pump();
    expect(find.text('第 1 / 4 拍'), findsOneWidget);
    await tester.tap(find.byTooltip('加快 1 BPM'));
    await tester.pump();
    expect(find.text('101 BPM'), findsOneWidget);
    expect(find.text('第 1 / 4 拍'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('开始节拍'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('开始节拍'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('准备声音时后台取消加载，不会稍后响起', (tester) async {
    final audio = FakeMetronomeAudio()..loading = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: MetronomePage(audio: audio)));
    await tester.tap(find.text('开始节拍'));
    await tester.pump();
    expect(find.text('正在准备声音…'), findsOneWidget);
    expect(find.text('停止节拍'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    audio.loading!.complete();
    await tester.pump();
    expect(audio.starts, 0);
    expect(audio.audible, isFalse);
    expect(find.text('开始节拍'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('大字号窄屏可滚动操作并退出', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MetronomePage(audio: FakeMetronomeAudio()),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('开始节拍'), 100);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
