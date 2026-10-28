import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/effects/effects_backend.dart';
import 'package:guitarbook/features/looper/effects_loop_input.dart';
import 'package:guitarbook/features/looper/looper_controller.dart';

import 'looper_test.dart' show FakeOutput;

class WetHost extends EffectsBackend {
  bool running = true;
  bool active = false;
  bool disposed = false;
  Completer<Map<String, dynamic>>? pending;
  List<int> pcm = [0, 16, 0, 240];
  int reads = 0;

  @override
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (command == 'loopStart') {
      if (!running) throw StateError('请先开始监听');
      active = true;
      return {'sampleRate': 48000};
    }
    if (command == 'loopStop') active = false;
    if (command == 'loopRead') {
      reads++;
      if (!running) throw StateError('监听已停止');
      if (pending != null) return pending!.future;
      return {'pcm': base64Encode(pcm)};
    }
    return {};
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  test('wet PCM reaches the looper and stopping keeps monitoring', () async {
    final host = WetHost();
    final input = EffectsLoopInput(host);
    final output = FakeOutput();
    final controller = LooperController(input, () => output);
    // 0.4 seconds of processed signal, below the layer normalization ceiling.
    host.pcm = List.generate(19200 * 2, (i) => i.isEven ? 0 : 8);
    controller.mainPedal();
    await controller.settled;
    expect(controller.recording, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    controller.mainPedal();
    await controller.settled;
    expect(controller.layers, 1);
    expect(output.pattern!.samples[500], closeTo(0.0625, 0.0001));
    controller.stop();
    await controller.settled;
    expect(host.active, isFalse);
    expect(host.running, isTrue);
    expect(host.disposed, isFalse);
    controller.dispose();
    await controller.settled;
  });

  test('missing monitoring fails explicitly and can retry', () async {
    final host = WetHost()..running = false;
    final controller = LooperController(EffectsLoopInput(host), FakeOutput.new);
    controller.mainPedal();
    await controller.settled;
    expect(controller.error, contains('请先开始监听'));
    expect(controller.capturing, isFalse);
    host.running = true;
    controller.mainPedal();
    await controller.settled;
    expect(controller.recording, isTrue);
    host.running = false;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await controller.settled;
    expect(controller.recording, isFalse);
    expect(controller.error, contains('监听已停止'));
    controller.dispose();
    await controller.settled;
  });

  test('reads do not overlap and late data is discarded after stop', () async {
    final host = WetHost()..pending = Completer<Map<String, dynamic>>();
    final input = EffectsLoopInput(host);
    final stream = await input.start(null);
    final received = <List<int>>[];
    final subscription = stream.listen(received.add);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.reads, 1);
    await input.stop();
    host.pending!.complete({
      'pcm': base64Encode([0, 1]),
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    await subscription.cancel();
    await input.dispose();
  });
}
