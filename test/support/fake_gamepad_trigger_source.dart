import 'dart:async';

import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';

/// 测试用的手柄输入源：手动推送快照，记录启停调用。
class FakeGamepadTriggerSource implements GamepadTriggerSource {
  final StreamController<GamepadSnapshot> _controller =
      StreamController<GamepadSnapshot>.broadcast();
  final List<PedalTrigger> startCalls = <PedalTrigger>[];
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  bool supported = true;

  @override
  String? platformNote;

  @override
  Stream<GamepadSnapshot> get snapshots => _controller.stream;

  void push(GamepadSnapshot snapshot) {
    if (!_controller.isClosed) _controller.add(snapshot);
  }

  void pushError(Object error) {
    if (!_controller.isClosed) _controller.addError(error);
  }

  @override
  Future<void> start(PedalTrigger trigger) async {
    startCalls.add(trigger);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _controller.close();
  }
}
