import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

enum PedalAction {
  main('录音 / 结束 / 叠录'),
  stop('停止 / 恢复'),
  undo('撤销最近一层'),
  clear('清空全部');

  const PedalAction(this.label);
  final String label;
}

const pedalMouseButtons = {
  kMiddleMouseButton: '鼠标中键',
  kBackMouseButton: '鼠标侧键 1',
  kForwardMouseButton: '鼠标侧键 2',
};

class PedalBindings {
  final keys = <PedalAction, LogicalKeyboardKey>{
    PedalAction.main: LogicalKeyboardKey.space,
    PedalAction.stop: LogicalKeyboardKey.keyS,
    PedalAction.undo: LogicalKeyboardKey.keyZ,
    PedalAction.clear: LogicalKeyboardKey.keyX,
  };
  final mouse = <PedalAction, int>{};
  PedalAction? learning;

  bool key(KeyEvent event, void Function(PedalAction) trigger) {
    if (event.synthesized) {
      return learning != null || keys.containsValue(event.logicalKey);
    }
    if (event is! KeyDownEvent) {
      return learning != null || keys.containsValue(event.logicalKey);
    }
    final target = learning;
    if (target != null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        learning = null;
        return true;
      }
      keys.removeWhere((_, key) => key == event.logicalKey);
      keys[target] = event.logicalKey;
      learning = null;
      return true;
    }
    for (final entry in keys.entries) {
      if (event.logicalKey == entry.value) {
        trigger(entry.key);
        return true;
      }
    }
    return false;
  }

  void bindMouse(PedalAction action, int? button) {
    mouse.remove(action);
    if (button != null) {
      mouse.removeWhere((_, value) => value == button);
      mouse[action] = button;
    }
  }

  void pointer(int buttons, void Function(PedalAction) trigger) {
    // Exact match avoids retriggering a held button in a multi-button chord.
    for (final entry in mouse.entries) {
      if (buttons == entry.value) {
        trigger(entry.key);
        return;
      }
    }
  }
}
