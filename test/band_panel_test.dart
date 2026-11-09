import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/band/band_controller.dart';
import 'package:guitarbook/features/band/band_panel.dart';
import 'package:guitarbook/features/band/chord_progression.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

/// 测试用的循环音频：只记录调用，不产生声音。
class _FakeAudio implements PositionedLoopAudio {
  final List<MetronomePattern> prepared = [];
  final List<Duration> playAtOffsets = [];
  int silenceCount = 0;
  int disposeCount = 0;
  Duration _position = Duration.zero;

  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) async {
    prepared.add(pattern);
  }

  @override
  void play() {}

  @override
  void playAt(Duration offset) {
    playAtOffsets.add(offset);
    _position = offset;
  }

  @override
  void setGain(double gain) {}

  @override
  Duration get position => _position;

  @override
  void silence() => silenceCount++;

  @override
  Future<void> clear() async {}

  @override
  Future<void> dispose() async => disposeCount++;
}

void main() {
  testWidgets('面板给出进行、方式、音量与状态', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final audio = _FakeAudio();
    final controller = BandController(audioFactory: () => audio);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BandPanel(controller: controller))),
    );

    expect(find.byKey(const ValueKey('band-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('band-chord')), findsOneWidget);
    expect(find.byKey(const ValueKey('band-volume')), findsOneWidget);
    expect(find.byKey(const ValueKey('band-toggle')), findsOneWidget);
    expect(find.text('BAND CHORDS'), findsOneWidget);
    expect(find.text('乐队 · 和弦进行'), findsOneWidget);
    expect(find.text('开始和弦进行'), findsOneWidget);
    expect(find.textContaining('未开启'), findsOneWidget);

    // 还没有演奏时和弦栏是破折号。
    final chip = find.byKey(const ValueKey('band-chord'));
    expect(
      find.descendant(of: chip, matching: find.text('—')),
      findsOneWidget,
    );
  });

  testWidgets('开关、选择与音量都能操作', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final audio = _FakeAudio();
    final controller = BandController(audioFactory: () => audio);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BandPanel(controller: controller))),
    );

    // 开始和弦进行。
    await tester.tap(find.byKey(const ValueKey('band-toggle')));
    await tester.pump();
    expect(audio.prepared.length, 1);
    expect(controller.playing, isTrue);
    expect(find.text('停止和弦进行'), findsOneWidget);

    // 播放位置推进后和弦栏显示当前和弦。
    await tester.pump(const Duration(milliseconds: 150));
    final chip = find.byKey(const ValueKey('band-chord'));
    expect(
      find.descendant(
        of: chip,
        matching: find.text(controller.progression.chordAt(0).shortName),
      ),
      findsOneWidget,
    );

    // 切换演奏方式。
    await tester.tap(
      find.byKey(ValueKey('band-style-${ChordPlayStyle.arpeggio.name}')),
    );
    await tester.pump();
    expect(controller.style, ChordPlayStyle.arpeggio);

    // 切换和弦进行。
    final other = bandProgressions.firstWhere(
      (progression) => progression.name != controller.progression.name,
      orElse: () => controller.progression,
    );
    await tester.tap(
      find.byKey(ValueKey('band-progression-${other.name}')),
    );
    await tester.pump();
    expect(controller.progression.name, other.name);

    // 拖动音量条。
    final before = controller.volume;
    await tester.drag(
      find.byKey(const ValueKey('band-volume')),
      const Offset(150, 0),
    );
    await tester.pump();
    expect(controller.volume, isNot(before));

    // 停止和弦进行，并收掉定时器。
    await tester.tap(find.byKey(const ValueKey('band-toggle')));
    await tester.pump();
    expect(controller.playing, isFalse);
    expect(audio.silenceCount, greaterThanOrEqualTo(1));
    expect(audio.disposeCount, 1);

    // 让淡出与对齐用的定时器有机会跑完，用例结束时不能留下未取消的定时器。
    await tester.pump(const Duration(milliseconds: 50));
  });
}
