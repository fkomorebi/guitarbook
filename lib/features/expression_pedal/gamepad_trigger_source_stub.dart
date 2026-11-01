import 'gamepad_trigger.dart';

/// Web 端没有读取手柄线性扳机的通道。
GamepadTriggerSource createGamepadTriggerSource() =>
    UnsupportedGamepadTriggerSource(
      'Web 版暂不支持读取手柄线性扳机，请在 Linux 或 Windows 桌面版使用。',
    );
