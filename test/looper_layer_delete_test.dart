import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:guitarbook/features/looper/loop_audio.dart';
import 'package:guitarbook/features/looper/looper_controller.dart';
import 'package:guitarbook/features/looper/looper_panel.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

class _Input implements LoopInput {
  StreamController<Uint8List>? stream;
  bool active = false;

  @override
  Future<List<InputDevice>> devices() async => [
    const InputDevice(id: 'usb', label: 'USB guitar'),
  ];

  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async {
    active = true;
    stream = StreamController<Uint8List>();
    return stream!.stream;
  }

  void emit(int frames) {
    final bytes = ByteData(frames * 2);
    for (var i = 0; i < frames; i++) {
      bytes.setInt16(i * 2, 12000, Endian.little);
    }
    stream!.add(bytes.buffer.asUint8List());
  }

  @override
  Future<void> stop() async {
    active = false;
    if (stream != null) unawaited(stream!.close());
    stream = null;
  }

  @override
  Future<void> dispose() => stop();
}

class _Output implements PositionedLoopAudio {
  double gain = 1;
  bool playing = false;
  bool disposed = false;
  Duration offset = Duration.zero;
  MetronomePattern? pattern;
  Completer<void>? loading;

  @override
  void setGain(double gain) => this.gain = gain;

  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) async {
    this.pattern = pattern;
    await loading?.future;
  }

  @override
  void play() => playAt(Duration.zero);

  @override
  void playAt(Duration offset) {
    this.offset = offset;
    playing = true;
  }

  @override
  Duration get position => offset;

  @override
  void silence() {
    playing = false;
  }

  @override
  Future<void> clear() async {
    playing = false;
  }

  @override
  Future<void> dispose() async {
    playing = false;
    disposed = true;
  }
}

/// Records one layer. The first call creates the base layer that defines the
/// loop length, later calls overdub on top of it.
Future<void> _recordLayer(
  LooperController c,
  _Input input, {
  int frames = 48000,
}) async {
  c.mainPedal();
  await c.settled;
  input.emit(frames);
  await Future<void>.delayed(Duration.zero);
  c.mainPedal();
  await c.settled;
}

/// 组件测试跑在假时间区，只有 pump 才会推进控制器里的异步队列。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 80; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: '等待控制器状态超时');
}

/// 在组件测试的假时间区里录一层：录音任务要靠 pump 推进。
Future<void> _recordLayerInWidget(
  WidgetTester tester,
  LooperController c,
  _Input input, {
  int frames = 48000,
}) async {
  final before = c.layers;
  c.mainPedal();
  await _pumpUntil(tester, () => c.recording);
  input.emit(frames);
  await tester.pump();
  await tester.pump();
  c.mainPedal();
  await _pumpUntil(tester, () => c.layers == before + 1);
}

void main() {
  test('删除中间层后其余层仍在且循环长度不变', () async {
    final input = _Input();
    final outputs = <_Output>[];
    final c = LooperController(input, () {
      final audio = _Output();
      outputs.add(audio);
      return audio;
    });
    await _recordLayer(c, input);
    await _recordLayer(c, input, frames: 24000);
    await _recordLayer(c, input, frames: 24000);
    expect(c.layers, 3);
    final loopFrames = c.frames;
    expect(loopFrames, 48000);

    expect(c.removeLayer(1), isTrue);
    await c.settled;
    expect(c.layers, 2);
    expect(c.frames, loopFrames);
    expect(c.seconds, closeTo(1, .0001));
    expect(c.playing, isTrue);
    // 被删的层释放音源，其余两层继续播放。
    expect(outputs[1].disposed, isTrue);
    expect(outputs[0].playing, isTrue);
    expect(outputs[2].playing, isTrue);
    expect(outputs[0].disposed, isFalse);
    expect(outputs[2].disposed, isFalse);
    c.dispose();
    await c.settled;
  });

  test('删除基准层后循环长度仍不变', () async {
    final input = _Input();
    final outputs = <_Output>[];
    final c = LooperController(input, () {
      final audio = _Output();
      outputs.add(audio);
      return audio;
    });
    await _recordLayer(c, input);
    await _recordLayer(c, input, frames: 24000);
    expect(c.layers, 2);
    final loopFrames = c.frames;

    expect(c.removeLayer(0), isTrue);
    await c.settled;
    expect(c.layers, 1);
    // 基准层没了，循环长度和播放状态保持不变。
    expect(c.frames, loopFrames);
    expect(c.seconds, closeTo(1, .0001));
    expect(c.playing, isTrue);
    expect(outputs[0].disposed, isTrue);
    expect(outputs[1].playing, isTrue);
    expect(outputs[1].disposed, isFalse);
    c.dispose();
    await c.settled;
  });

  test('删除唯一层后循环长度归零并停止播放', () async {
    final input = _Input();
    final outputs = <_Output>[];
    final c = LooperController(input, () {
      final audio = _Output();
      outputs.add(audio);
      return audio;
    });
    await _recordLayer(c, input);
    expect(c.layers, 1);
    expect(c.playing, isTrue);

    expect(c.removeLayer(0), isTrue);
    await c.settled;
    expect(c.layers, 0);
    expect(c.frames, 0);
    expect(c.seconds, 0);
    expect(c.playing, isFalse);
    expect(outputs.single.disposed, isTrue);
    c.dispose();
    await c.settled;
  });

  test('删除后撤销能恢复该层且相位对齐', () async {
    final input = _Input();
    final outputs = <_Output>[];
    final c = LooperController(input, () {
      final audio = _Output();
      outputs.add(audio);
      return audio;
    });
    await _recordLayer(c, input);
    outputs.first.offset = const Duration(milliseconds: 500);
    await _recordLayer(c, input, frames: 24000);
    // 叠录按当前相位加入循环。
    expect(outputs.last.offset, const Duration(milliseconds: 500));
    expect(c.layers, 2);

    expect(c.removeLayer(1), isTrue);
    await c.settled;
    expect(c.layers, 1);
    expect(c.frames, 48000);
    expect(c.error, isNull);

    expect(c.restoreRemovedLayer(), isTrue);
    await c.settled;
    expect(c.layers, 2);
    expect(c.frames, 48000);
    final restored = outputs.last;
    expect(restored.pattern!.samples.length, 48000);
    // 恢复的层按当前相位重新接入循环。
    expect(restored.offset, const Duration(milliseconds: 500));
    expect(restored.playing, isTrue);
    expect(restored.gain, c.playbackGain);
    c.dispose();
    await c.settled;
  });

  test('删除最后一层后撤销会恢复该层并重新开始循环', () async {
    final input = _Input();
    final outputs = <_Output>[];
    final c = LooperController(input, () {
      final audio = _Output();
      outputs.add(audio);
      return audio;
    });
    await _recordLayer(c, input);
    expect(c.removeLayer(0), isTrue);
    await c.settled;
    expect(c.layers, 0);
    expect(c.playing, isFalse);

    expect(c.restoreRemovedLayer(), isTrue);
    await c.settled;
    expect(c.layers, 1);
    expect(c.frames, 48000);
    expect(c.playing, isTrue);
    expect(outputs.last.playing, isTrue);
    c.dispose();
    await c.settled;
  });

  test('录音或忙碌期间不允许删除', () async {
    final input = _Input();
    final outputs = <_Output>[];
    // The next created output blocks its prepare so the controller stays busy.
    Completer<void>? blockPrepare;
    final c = LooperController(input, () {
      final audio = _Output()..loading = blockPrepare;
      outputs.add(audio);
      return audio;
    });
    await _recordLayer(c, input);

    // 录音中：删除被拒绝，层数不变。
    c.mainPedal();
    await c.settled;
    expect(c.recording, isTrue);
    expect(c.removeLayer(0), isFalse);
    expect(c.layers, 1);
    input.emit(24000);
    await Future<void>.delayed(Duration.zero);
    c.mainPedal();
    await c.settled;
    expect(c.layers, 2);

    // 音源准备未完成（busy）时同样不允许删除。
    final loading = Completer<void>();
    blockPrepare = loading;
    c.mainPedal();
    await Future<void>.delayed(Duration.zero);
    input.emit(24000);
    await Future<void>.delayed(Duration.zero);
    c.mainPedal();
    await Future<void>.delayed(Duration.zero);
    expect(c.busy, isTrue);
    expect(c.removeLayer(0), isFalse);
    expect(c.layers, 2);
    loading.complete();
    await c.settled;
    c.dispose();
    await c.settled;
  });

  test('清空后不能恢复已删除的层', () async {
    final input = _Input();
    final c = LooperController(input, _Output.new);
    await _recordLayer(c, input);
    expect(c.removeLayer(0), isTrue);
    await c.settled;
    c.clear();
    await c.settled;
    expect(c.restoreRemovedLayer(), isFalse);
    expect(c.layers, 0);
    expect(c.error, contains('没有可恢复'));
    c.dispose();
    await c.settled;
  });

  testWidgets('层级方块的删除按钮可删除该层并可撤销', (tester) async {
    final input = _Input();
    final outputs = <_Output>[];
    final c = LooperController(input, () {
      final audio = _Output();
      outputs.add(audio);
      return audio;
    });
    await _recordLayerInWidget(tester, c, input);
    await _recordLayerInWidget(tester, c, input, frames: 24000);
    // 停止采集，避免录音看门狗持续刷新界面。
    c.stop();
    await tester.pump();
    expect(c.layers, 2);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: LooperPanel(controller: c)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pump();
    expect(c.layers, 1);
    expect(find.text('已删除第 1 层'), findsOneWidget);

    // 等提示条进场完成再点撤销。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('撤销'));
    await _pumpUntil(tester, () => c.layers == 2);
    expect(c.layers, 2);
    expect(c.frames, 48000);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump();
  });

  testWidgets('紧凑布局下删除按钮同样可用', (tester) async {
    final input = _Input();
    final c = LooperController(input, _Output.new);
    await _recordLayerInWidget(tester, c, input);
    c.stop();
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LooperPanel(controller: c, compact: true, landscape: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(c.layers, 0);
    expect(find.text('已删除第 1 层'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump();
  });
}
