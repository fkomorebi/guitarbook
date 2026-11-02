import 'gamepad_trigger.dart';

/// 既不是桌面（dart:io）也不是网页（dart:js_interop）时的兜底实现。
GamepadTriggerSource createGamepadTriggerSource() =>
    UnsupportedGamepadTriggerSource(
      '当前平台暂不支持读取手柄线性扳机；'
      '目前支持 Linux 与 Windows 桌面版，以及浏览器（Gamepad API）。',
    );
