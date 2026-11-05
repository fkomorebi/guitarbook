import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:guitarbook/features/drums/drums_page.dart';
import 'package:guitarbook/features/looper/loop_audio.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';
import 'package:guitarbook/features/smart_bass/bass_pattern.dart';
import 'package:guitarbook/features/smart_bass/smart_bass_controller.dart';
import 'package:guitarbook/features/smart_bass/smart_bass_panel.dart';

class _FakeInput implements LoopInput {
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  @override
  Future<List<InputDevice>> devices() async => const <InputDevice>[];

  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async =>
      _controller.stream;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

class _FakeBassAudio implements PositionedLoopAudio {
  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) async {}

  @override
  void play() {}

  @override
  void playAt(Duration offset) {}

  @override
  void setGain(double gain) {}

  @override
  Duration get position => Duration.zero;

  @override
  void silence() {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeDrumAudio implements MetronomeAudio {
  @override
  void setGain(double value) {}

  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) async {}

  @override
  void play() {}

  @override
  Duration get position => Duration.zero;

  @override
  void silence() {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('面板给出开关、风格与状态', (tester) async {
    final controller = SmartBassController(
      input: _FakeInput(),
      audioFactory: _FakeBassAudio.new,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SmartBassPanel(controller: controller)),
      ),
    );

    expect(find.text('智能base'), findsOneWidget);
    expect(find.byKey(const ValueKey('smart-bass-toggle')), findsOneWidget);
    expect(find.text('开启智能base'), findsOneWidget);
    expect(find.text('跟底鼓'), findsOneWidget);
    expect(find.textContaining('未开启'), findsOneWidget);

    await tester.tap(find.text('走动低音'));
    await tester.pump();
    expect(controller.style, BassStyle.walking);
  });

  testWidgets('即兴工作台里出现智能base 面板', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DrumsPage(audio: _FakeDrumAudio(), recordingInput: _FakeInput()),
      ),
    );

    expect(find.byKey(const ValueKey('smart-bass-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('smart-bass-toggle')), findsOneWidget);
    expect(find.text('智能base'), findsOneWidget);
  });
}
