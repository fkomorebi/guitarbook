import 'dart:typed_data';

import 'gamepad_trigger.dart';

/// Linux 输入事件类型（linux/input-event-codes.h）。
const int evKey = 0x01;
const int evAbs = 0x03;

/// 手柄扳机相关的绝对轴编码。
const int absZ = 0x02;
const int absRz = 0x05;
const int absGas = 0x09;
const int absBrake = 0x0a;

/// 内核文档建议手柄扳机使用 ABS_HAT2X / ABS_HAT2Y。
const int absHat2X = 0x14;
const int absHat2Y = 0x15;

/// 64 位 Linux 上 `struct input_event` 的字节数：
/// `timeval`（16 字节）+ `__u16 type` + `__u16 code` + `__s32 value`。
///
/// 目前只在 64 位桌面 Linux（x86_64 / aarch64）上读取；32 位系统的事件为
/// 16 字节，需要另外适配。
const int evdevEventSize = 24;

/// 按内核 gamepad 文档与 SDL 的探测顺序解析某个扳机对应的 ABS 编码；
/// 没有可用轴时返回 null。
///
/// 优先 ABS_HAT2Y / ABS_HAT2X（内核建议的扳机轴），其次通用油门/刹车轴
/// ABS_GAS / ABS_BRAKE，最后是 Xbox / DualShock 系列常用的 ABS_Z / ABS_RZ。
/// 顺序与 SDL 的 `SDL_sysjoystick.c` 一致。
const List<int> _leftTriggerAxes = [absHat2Y, absBrake, absZ];
const List<int> _rightTriggerAxes = [absHat2X, absGas, absRz];

/// `/proc/bus/input/devices` 中一个输入设备的摘要。
class EvdevDevice {
  const EvdevDevice({
    required this.name,
    required this.eventHandler,
    required this.absBits,
    this.joystickHandler,
  });

  final String name;

  /// `/dev/input` 下的事件节点名，例如 `event5`。
  final String eventHandler;

  /// `B: ABS=` 能力位图，第 n 位对应 ABS 编码 n。
  final BigInt absBits;

  /// 内核注册的 joystick 节点名，例如 `js2`；没有则为空。
  ///
  /// 有 joystick 节点说明内核把它当成手柄/摇杆；如果同时又没有线性扳机轴，
  /// 就多半是 Switch Pro 这类“数字按键式扳机”。
  final String? joystickHandler;
}

/// 在位的绝对轴编码。
bool hasAbsCode(BigInt absBits, int code) =>
    ((absBits >> code) & BigInt.one) != BigInt.zero;

/// 按常见手柄的轴布局解析某个扳机对应的 ABS 编码；没有可用轴时返回 null。
///
/// Xbox / DualShock 系列用 ABS_Z（左）与 ABS_RZ（右）；部分驱动使用
/// ABS_GAS / ABS_BRAKE。
int? resolveTriggerAxis(BigInt absBits, PedalTrigger trigger) {
  final candidates = trigger == PedalTrigger.left
      ? _leftTriggerAxes
      : _rightTriggerAxes;
  for (final code in candidates) {
    if (hasAbsCode(absBits, code)) return code;
  }
  return null;
}

/// 设备是否带有任意一路可用的线性扳机轴。
bool supportsAnalogTrigger(BigInt absBits) =>
    resolveTriggerAxis(absBits, PedalTrigger.left) != null ||
    resolveTriggerAxis(absBits, PedalTrigger.right) != null;

/// 摇杆类绝对轴：摇杆、方向键、油门刹车等。
///
/// 只带 ABS_X / ABS_Y 的设备多半是触控板或绘图板，不是手柄。
const List<int> _stickLikeAxes = [
  absZ, // ABS_Z
  0x03, // ABS_RX
  0x04, // ABS_RY
  absRz, // ABS_RZ
  0x06, // ABS_THROTTLE
  0x07, // ABS_RUDDER
  0x08, // ABS_WHEEL
  absGas, // ABS_GAS
  absBrake, // ABS_BRAKE
  0x10, // ABS_HAT0X
  0x11, // ABS_HAT0Y
  0x12, // ABS_HAT1X
  0x13, // ABS_HAT1Y
  absHat2X, // ABS_HAT2X
  absHat2Y, // ABS_HAT2Y
];

/// 设备看起来是不是手柄。
///
/// 内核会把触控板（QEMU tablet、spice vdagent）也注册成 joystick 节点，
/// 只看 joystick 节点会把它们误当成“数字按键式扳机”的手柄。这里要求设备
/// 至少还有一路摇杆类的绝对轴，才认为是手柄。
bool looksLikeGamepad(EvdevDevice device) {
  if (device.joystickHandler == null) return false;
  for (final code in _stickLikeAxes) {
    if (hasAbsCode(device.absBits, code)) return true;
  }
  return false;
}

/// 解析 `/proc/bus/input/devices` 文本，只保留带 `eventN` 节点的设备。
List<EvdevDevice> parseProcInputDevices(String text) {
  final devices = <EvdevDevice>[];
  String? name;
  BigInt absBits = BigInt.zero;
  String? eventHandler;
  String? joystickHandler;

  void flush() {
    final deviceName = name;
    final handler = eventHandler;
    if (deviceName != null && handler != null) {
      devices.add(
        EvdevDevice(
          name: deviceName,
          eventHandler: handler,
          absBits: absBits,
          joystickHandler: joystickHandler,
        ),
      );
    }
    name = null;
    absBits = BigInt.zero;
    eventHandler = null;
    joystickHandler = null;
  }

  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    if (line.startsWith('N: Name=')) {
      name = _unquote(line.substring('N: Name='.length));
    } else if (line.startsWith('H: Handlers=')) {
      for (final token
          in line.substring('H: Handlers='.length).split(RegExp(r'\s+'))) {
        if (token.startsWith('event') && token.length > 'event'.length) {
          eventHandler = token;
        } else if (token.startsWith('js') && token.length > 'js'.length) {
          joystickHandler = token;
        }
      }
    } else if (line.startsWith('B: ABS=')) {
      absBits = parseAbsBitmap(line.substring('B: ABS='.length));
    }
  }
  flush();
  return devices;
}

/// 解析 `B: ABS=` 后的十六进制位图。
///
/// 内核按 `BITS_TO_LONGS(ABS_CNT) - 1` 到 0 的顺序打印（见
/// `drivers/input/input.c`），也就是**高位字在前**；64 位系统上 ABS 位图只有
/// 一个 64 位字，32 位系统上才是两个 32 位字。
BigInt parseAbsBitmap(String text) {
  var bits = BigInt.zero;
  final words = text
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  for (var index = 0; index < words.length; index++) {
    final word = BigInt.parse(words[index], radix: 16);
    bits |= word << (32 * (words.length - 1 - index));
  }
  return bits;
}

String _unquote(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

/// 一条 evdev 事件。
class EvdevEvent {
  const EvdevEvent({
    required this.type,
    required this.code,
    required this.value,
  });

  final int type;
  final int code;
  final int value;
}

/// 把按块到达的字节流拆成 `input_event`；不完整的尾部留到下一次。
class EvdevEventBuffer {
  Uint8List _bytes = Uint8List(0);
  int _start = 0;

  /// 追加一段字节，返回其中解析出的完整事件。
  List<EvdevEvent> add(List<int> chunk) {
    final pending = _bytes.length - _start;
    final merged = Uint8List(pending + chunk.length);
    merged.setRange(0, pending, _bytes, _start);
    merged.setRange(pending, merged.length, chunk);
    _bytes = merged;
    _start = 0;

    final data = ByteData.sublistView(_bytes);
    final events = <EvdevEvent>[];
    var offset = 0;
    while (_bytes.length - offset >= evdevEventSize) {
      events.add(
        EvdevEvent(
          type: data.getUint16(offset + 16, Endian.host),
          code: data.getUint16(offset + 18, Endian.host),
          value: data.getInt32(offset + 20, Endian.host),
        ),
      );
      offset += evdevEventSize;
    }
    _start = offset;
    return events;
  }

  void reset() {
    _bytes = Uint8List(0);
    _start = 0;
  }
}
