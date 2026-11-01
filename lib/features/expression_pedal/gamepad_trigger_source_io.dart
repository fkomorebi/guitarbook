import 'dart:io';

import 'gamepad_trigger.dart';
import 'linux_gamepad_trigger_source.dart';
import 'windows_gamepad_trigger_source.dart';

/// 按桌面平台选择手柄扳机读取实现。
GamepadTriggerSource createGamepadTriggerSource() {
  if (Platform.isLinux) return LinuxGamepadTriggerSource();
  if (Platform.isWindows) return WindowsGamepadTriggerSource();
  return UnsupportedGamepadTriggerSource(
    '当前系统（${Platform.operatingSystem}）暂不支持读取手柄线性扳机；'
    '目前只支持 Linux 与 Windows 桌面版。',
  );
}
