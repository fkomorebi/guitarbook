import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:guitarbook/features/looper/loop_audio.dart';
import 'package:guitarbook/features/looper/loop_samples.dart';
import 'package:guitarbook/features/looper/looper_controller.dart';
import 'package:guitarbook/features/looper/looper_panel.dart';
import 'package:guitarbook/features/looper/pedal_bindings.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

class FakeInput implements LoopInput {
  StreamController<Uint8List>? stream;
  bool active = false;
  bool denied = false;
  Completer<void>? starting;
  @override
  Future<List<InputDevice>> devices() async => [
    const InputDevice(id: 'usb', label: 'USB guitar'),
  ];
  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async {
    if (denied) throw StateError('permission denied');
    await starting?.future;
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

class FakeOutput implements PositionedLoopAudio {
  double gain = 1;
  @override
  void setGain(double gain) => this.gain = gain;

  bool playing = false;
  bool disposed = false;
  bool failUnlock = false;
  Duration offset = Duration.zero;
  MetronomePattern? pattern;
  Completer<void>? loading;
  @override
  Future<void> unlock() async {
    if (failUnlock) throw StateError('unlock failed');
  }

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

void main() {
  test(
    'smart first layer auto finishes, overdubs retain full loop length',
    () async {
      final input = FakeInput();
      final output = <FakeOutput>[];
      final c = LooperController(input, () {
        final audio = FakeOutput();
        output.add(audio);
        return audio;
      });
      c.setSmartEnabled(true);
      c.mainPedal();
      await c.settled;
      expect(c.smartWaiting, isTrue);
      input.stream!.add(Uint8List(loopSampleRate)); // Half second calibration.
      input.emit(loopSampleRate);
      input.stream!.add(Uint8List(loopSampleRate * 4));
      await Future<void>.delayed(Duration.zero);
      await c.settled;
      expect(c.layers, 1);
      expect(c.playing, isTrue);
      expect(c.seconds, closeTo(1.13, .02));
      c.mainPedal();
      await c.settled;
      expect(c.smartWaiting, isFalse);
      input.emit(c.frames);
      await Future<void>.delayed(Duration.zero);
      await c.settled;
      expect(c.layers, 2);
      expect(output.last.pattern!.samples.length, c.frames);
      c.dispose();
      await c.settled;
    },
  );

  test(
    'smart waiting cancel and stop during output preparation release audio',
    () async {
      final input = FakeInput();
      final output = <FakeOutput>[];
      final c = LooperController(input, () {
        final audio = FakeOutput();
        output.add(audio);
        return audio;
      });
      c.setSmartEnabled(true);
      c.mainPedal();
      await c.settled;
      c.mainPedal(); // Cancel while waiting.
      await c.settled;
      expect(c.capturing, isFalse);
      expect(c.layers, 0);
      expect(output.single.disposed, isTrue);
      c.mainPedal();
      await c.settled;
      final loading = Completer<void>();
      output.last.loading = loading;
      input.stream!.add(Uint8List(loopSampleRate));
      input.emit(loopSampleRate);
      input.stream!.add(Uint8List(loopSampleRate * 4));
      await Future<void>.delayed(Duration.zero);
      c.stop();
      loading.complete();
      await c.settled;
      expect(c.layers, 0);
      expect(output.last.disposed, isTrue);
      c.dispose();
      await c.settled;
    },
  );

  testWidgets(
    'smart toggle, waiting status and sensitivity work at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = LooperController(FakeInput(), FakeOutput.new);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SingleChildScrollView(child: LooperPanel(controller: c)),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(c.smartEnabled, isTrue);
      c.mainPedal();
      await tester.pump();
      expect(find.text('检测底噪 · 请安静半秒'), findsOneWidget);
      expect(find.text('取消等待'), findsWidgets);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      c.stop();
      await tester.pump();
      await tester.ensureVisible(find.byTooltip('踏板绑定与录音设置'));
      await tester.tap(find.byTooltip('踏板绑定与录音设置'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('smart-threshold'));
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(40, 0));
      await tester.pump();
      expect(c.smartThresholdDb, greaterThan(-45));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump();
    },
  );

  test('input meter detects silence, split PCM and signal recovery', () {
    final meter = LoopInputMeter();
    meter.add(Uint8List(loopSampleRate * 3 * 2));
    expect(meter.quiet, isTrue);
    expect(meter.db, -96);
    meter.add(Uint8List.fromList([0]));
    meter.add(Uint8List.fromList([128]));
    expect(meter.peak, 1);
    expect(meter.db, 0);
    expect(meter.quiet, isFalse);
    meter.add(Uint8List.fromList([255, 127]));
    expect(meter.peak, closeTo(32767 / 32768, .00001));
  });

  test(
    'quiet takes retain input gain while loud takes reserve six-layer headroom',
    () {
      for (final amplitude in [0, 3277, 16000, 32767]) {
        final take = LoopTake(1000);
        final bytes = ByteData(2000);
        for (var i = 0; i < 1000; i++) {
          bytes.setInt16(i * 2, amplitude, Endian.little);
        }
        take.add(bytes.buffer.asUint8List());
        final samples = take.finish(length: 1000, offset: 0);
        final expected = amplitude / 32768 > .12 ? .12 : amplitude / 32768;
        expect(samples[500], closeTo(expected, .000001));
        expect(samples[500] * 6, lessThanOrEqualTo(.720001));
        expect(samples.first, 0);
        expect(samples.last, 0);
      }
    },
  );
  test(
    'PCM decoding preserves split samples and clamps recording duration',
    () {
      final take = LoopTake(3);
      take.add(Uint8List.fromList([0, 128, 255]));
      take.add(Uint8List.fromList([127, 0, 64, 20, 30]));
      expect(take.count, 3);
      final samples = take.finish(length: 3, offset: 0);
      expect(samples.first, 0);
      expect(samples.last, 0);
      expect(samples[1], closeTo(32767 / 32768 * .12, .00001));
      expect(phaseFrame(const Duration(milliseconds: 10), 48000, 20), 47520);
    },
  );

  test('phase rotation places a take across the loop boundary', () {
    final take = LoopTake(480);
    final data = ByteData(960);
    for (var i = 0; i < 480; i++) {
      data.setInt16(i * 2, 16000, Endian.little);
    }
    take.add(data.buffer.asUint8List());
    final result = take.finish(length: 960, offset: 800);
    expect(result[800], 0);
    expect(result[50], greaterThan(0));
    expect(result[500], 0);
  });

  test(
    'record, overdub without interrupting base, undo, stop and resume',
    () async {
      final input = FakeInput();
      final outputs = <FakeOutput>[];
      final c = LooperController(input, () {
        final a = FakeOutput();
        outputs.add(a);
        return a;
      });
      c.setPlaybackGain(2);
      c.mainPedal();
      await c.settled;
      expect(c.recording, isTrue);
      input.emit(48000);
      await Future<void>.delayed(Duration.zero);
      c.mainPedal();
      await c.settled;
      expect(c.layers, 1);
      expect(c.playing, isTrue);
      expect(c.seconds, 1);
      expect(outputs.first.gain, 2);
      c.setPlaybackGain(3);
      expect(outputs.first.gain, 3);
      outputs.first.offset = const Duration(milliseconds: 500);
      c.mainPedal();
      await c.settled;
      input.emit(24000);
      await Future<void>.delayed(Duration.zero);
      c.mainPedal();
      await c.settled;
      expect(c.layers, 2);
      expect(outputs.last.gain, 3);
      c.setPlaybackGain(0);
      expect(outputs.every((a) => a.gain == 0), isTrue);
      c.setPlaybackGain(10);
      expect(c.playbackGain, 4);
      expect(outputs.first.playing, isTrue);
      expect(outputs.last.offset, const Duration(milliseconds: 500));
      c.undo();
      await c.settled;
      expect(c.layers, 1);
      expect(outputs.last.disposed, isTrue);
      c.stop();
      await c.settled;
      expect(input.active, isFalse);
      expect(c.layers, 1);
      c.resume();
      await c.settled;
      expect(c.playing, isTrue);
      expect(outputs.first.offset, Duration.zero);
      expect(outputs.first.gain, 4);
      c.clear();
      await c.settled;
      expect(c.layers, 0);
      expect(outputs.first.disposed, isTrue);
      c.dispose();
      await c.settled;
    },
  );

  test(
    'stop during initial device startup cancels the take and armed output',
    () async {
      final input = FakeInput()..starting = Completer<void>();
      final output = FakeOutput();
      final c = LooperController(input, () => output);
      c.mainPedal();
      await Future<void>.delayed(Duration.zero);
      c.stop();
      input.starting!.complete();
      await c.settled;
      expect(c.recording, isFalse);
      expect(input.active, isFalse);
      expect(output.disposed, isTrue);
      c.dispose();
      await c.settled;
    },
  );

  test('stop during layer load never plays obsolete audio', () async {
    final input = FakeInput();
    final output = FakeOutput()..loading = Completer<void>();
    final c = LooperController(input, () => output);
    c.mainPedal();
    await c.settled;
    input.emit(24000);
    await Future<void>.delayed(Duration.zero);
    c.mainPedal();
    await Future<void>.delayed(Duration.zero);
    c.stop();
    output.loading!.complete();
    await c.settled;
    expect(output.playing, isFalse);
    expect(output.disposed, isTrue);
    expect(c.layers, 0);
    c.dispose();
    await c.settled;
  });

  test(
    'permission failure recovers, input failure stops, partial take discarded',
    () async {
      final input = FakeInput()..denied = true;
      final c = LooperController(input, FakeOutput.new);
      c.mainPedal();
      await c.settled;
      expect(c.error, contains('permission'));
      expect(c.capturing, isFalse);
      input.denied = false;
      c.mainPedal();
      await c.settled;
      input.emit(100);
      await Future<void>.delayed(Duration.zero);
      c.mainPedal();
      expect(c.recording, isTrue);
      expect(c.error, contains('0.3'));
      input.stream!.addError(StateError('disconnected'));
      await Future<void>.delayed(Duration.zero);
      await c.settled;
      expect(c.recording, isFalse);
      expect(c.layers, 0);
      expect(c.error, contains('中断'));
      c.dispose();
      await c.settled;
    },
  );

  test(
    'one full loop automatically commits overdub and enforces six layers',
    () async {
      final input = FakeInput();
      final c = LooperController(input, FakeOutput.new);
      c.mainPedal();
      await c.settled;
      input.emit(14400);
      await Future<void>.delayed(Duration.zero);
      c.mainPedal();
      await c.settled;
      for (var i = 1; i < 6; i++) {
        c.mainPedal();
        await c.settled;
        input.emit(20000);
        await Future<void>.delayed(Duration.zero);
        await c.settled;
        expect(c.layers, i + 1);
        expect(c.recording, isFalse);
      }
      c.mainPedal();
      expect(c.error, contains('最多'));
      expect(c.recording, isFalse);
      c.dispose();
      await c.settled;
    },
  );

  test(
    'stop immediately after commit releases the not-yet-loaded output',
    () async {
      final input = FakeInput();
      final output = FakeOutput();
      final c = LooperController(input, () => output);
      c.mainPedal();
      await c.settled;
      input.emit(24000);
      await Future<void>.delayed(Duration.zero);
      c.mainPedal();
      c.stop();
      await c.settled;
      expect(output.disposed, isTrue);
      expect(output.playing, isFalse);
      c.dispose();
      await c.settled;
    },
  );

  test('first take automatically ends at 30 seconds', () async {
    final input = FakeInput();
    final c = LooperController(input, FakeOutput.new);
    c.mainPedal();
    await c.settled;
    input.emit(maxLoopFrames + 1000);
    await Future<void>.delayed(Duration.zero);
    await c.settled;
    expect(c.seconds, 30);
    expect(c.layers, 1);
    expect(c.playing, isTrue);
    c.dispose();
    await c.settled;
  });

  testWidgets('a disconnected input preserves completed layers', (
    tester,
  ) async {
    final input = FakeInput();
    final c = LooperController(input, FakeOutput.new);
    c.mainPedal();
    await tester.runAsync(() => c.settled);
    input.emit(24000);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    c.mainPedal();
    await tester.runAsync(() => c.settled);
    input.stream!.addError(StateError('disconnected'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.runAsync(() => c.settled);
    expect(c.layers, 1);
    expect(c.playing, isFalse);
    c.dispose();
    await tester.runAsync(() => c.settled);
  });

  test('key learning transfers duplicate bindings, repeats do not trigger', () {
    final bindings = PedalBindings();
    final actions = <PedalAction>[];
    final down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.space,
      logicalKey: LogicalKeyboardKey.space,
      timeStamp: Duration.zero,
    );
    bindings.key(down, actions.add);
    bindings.key(
      KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration.zero,
      ),
      actions.add,
    );
    expect(actions, [PedalAction.main]);
    bindings.learning = PedalAction.undo;
    bindings.key(down, actions.add);
    expect(bindings.keys.containsKey(PedalAction.main), isFalse);
    bindings.key(down, actions.add);
    expect(actions.last, PedalAction.undo);
    bindings.bindMouse(PedalAction.main, kMiddleMouseButton);
    bindings.bindMouse(PedalAction.stop, kMiddleMouseButton);
    bindings.pointer(kMiddleMouseButton, actions.add);
    expect(actions.last, PedalAction.stop);
    expect(bindings.mouse.length, 1);
  });

  testWidgets(
    'keyboard is consumed once, background stops, small large-text panel fits',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final input = FakeInput();
      final c = LooperController(input, FakeOutput.new);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SingleChildScrollView(child: LooperPanel(controller: c)),
            ),
          ),
        ),
      );
      final volume = find.byKey(const ValueKey('loop-volume'));
      await tester.ensureVisible(volume);
      await tester.drag(volume, const Offset(35, 0));
      await tester.pump();
      expect(c.playbackGain, greaterThan(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.recording, isTrue);
      input.emit(24000);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.layers, 1);
      expect(c.playing, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(c.playing, isFalse);
      expect(c.capturing, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.ensureVisible(find.byTooltip('踏板绑定与录音设置'));
      await tester.tap(find.byTooltip('踏板绑定与录音设置'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(c.devices.single.label, 'USB guitar');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump();
    },
  );
}
