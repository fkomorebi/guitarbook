import 'dart:typed_data';

import 'linux_evdev.dart';

/// 旧版 joystick 接口（`/dev/input/js*`）的 ABI 常量与解析。
///
/// Ubuntu 默认给 `js*` 节点 `0664`（`/lib/udev/rules.d/50-udev-default.rules`
/// 里的 `SUBSYSTEM=="input", KERNEL=="js[0-9]*", MODE="0664"`），任何用户
/// 都能直接打开，不需要 `input` 组或 udev 规则；而 `event*` 是 `0660
/// root:input`。所以当 evdev 节点打不开（EACCES）时，可以退回到这里读取。
///
/// 代价是量程被内核改过：`joydev` 会把绝对轴的值缩放到 `-32767..32767`
/// 并让 0 表示中点（见 `drivers/input/joydev.c` 的 `joydev_correct()`），
/// 所以这里再换算回 0..255 的扳机读数。

/// `struct js_event` 的字节数：`__u32 time`、`__s16 value`、`__u8 type`、
/// `__u8 number`。
const int jsEventSize = 8;

/// `struct js_event` 的事件类型。
const int jsEventButton = 0x01;
const int jsEventAxis = 0x02;

/// 打开设备时内核补发的一批“当前状态”事件会带上这个位。
const int jsEventInit = 0x80;

/// `ABS_CNT`：内核里绝对轴编码的上限，也是 `JSIOCGAXMAP` 表的大小。
const int jsAxisMapSize = 64;

/// `JSIOCGAXMAP`，即 `_IOR('j', 0x32, __u8[ABS_CNT])`。
///
/// 返回的表以「旧版轴号」为下标，值是对应的 evdev ABS 编码。
const int jsIoctlGetAxisMap =
    (2 << 30) | (jsAxisMapSize << 16) | (0x6a << 8) | 0x32;

/// 旧版接口的轴值范围：`joydev` 把绝对轴缩放到带符号的 16 位范围，
/// 0 表示中点。
const int jsValueMinimum = -32767;
const int jsValueMaximum = 32767;

/// 旧版接口下扳机的读数范围（与 Windows XInput 版一致，0 表示松开）。
const int jsTriggerRawMinimum = 0;
const int jsTriggerRawMaximum = 255;

/// 一条 `struct js_event`。
class JsEvent {
  const JsEvent({
    required this.time,
    required this.value,
    required this.type,
    required this.number,
  });

  /// 内核时间戳（毫秒，不是墙上时间）。
  final int time;

  /// 轴值或按键状态。
  final int value;

  /// 事件类型，可能带上 [jsEventInit] 位。
  final int type;

  /// 轴号或按键号。
  final int number;

  /// 去掉 [jsEventInit] 位之后的类型。
  int get kind => type & ~jsEventInit;

  /// 是不是轴事件（包括打开设备时的初始化事件）。
  bool get isAxis => kind == jsEventAxis;

  /// 是不是初始化事件。
  bool get isInit => (type & jsEventInit) != 0;
}

/// 把按块到达的字节流拆成 [JsEvent]；不完整的尾部留到下一次。
class JsEventBuffer {
  Uint8List _bytes = Uint8List(0);
  int _start = 0;

  /// 追加一段字节，返回其中解析出的完整事件。
  List<JsEvent> add(List<int> chunk) {
    final pending = _bytes.length - _start;
    final merged = Uint8List(pending + chunk.length);
    merged.setRange(0, pending, _bytes, _start);
    merged.setRange(pending, merged.length, chunk);
    _bytes = merged;
    _start = 0;

    final data = ByteData.sublistView(_bytes);
    final events = <JsEvent>[];
    var offset = 0;
    while (_bytes.length - offset >= jsEventSize) {
      events.add(
        JsEvent(
          time: data.getUint32(offset, Endian.host),
          value: data.getInt16(offset + 4, Endian.host),
          type: data.getUint8(offset + 6),
          number: data.getUint8(offset + 7),
        ),
      );
      offset += jsEventSize;
    }
    _start = offset;
    return events;
  }

  void reset() {
    _bytes = Uint8List(0);
    _start = 0;
  }
}

/// 旧版接口的轴值（`-32767..32767`，0 为中点）换算成 0..255 的扳机读数。
///
/// 扳机在 `0..255` 量程上映射到 `-32767..32767`，所以松开时读出 0，
/// 按到底读出 255。
int jsTriggerRaw(int value) {
  final clamped = value < jsValueMinimum
      ? jsValueMinimum
      : (value > jsValueMaximum ? jsValueMaximum : value);
  final scaled =
      (clamped - jsValueMinimum) *
      jsTriggerRawMaximum /
      (jsValueMaximum - jsValueMinimum);
  final rounded = scaled.round();
  if (rounded < jsTriggerRawMinimum) return jsTriggerRawMinimum;
  if (rounded > jsTriggerRawMaximum) return jsTriggerRawMaximum;
  return rounded;
}

/// 在 `JSIOCGAXMAP` 返回的表里找出某个 ABS 编码对应的旧版轴号。
int? jsAxisIndexFor(List<int> axisMap, int absCode) {
  for (var index = 0; index < axisMap.length; index++) {
    if (axisMap[index] == absCode) return index;
  }
  return null;
}

/// ioctl 不可用时的退路：`joydev` 按设备上报的 ABS 编码升序编号，
/// 所以旧版轴号等于“比它小的已上报轴的数量”。
int? jsAxisIndexFromBits(BigInt absBits, int absCode) {
  if (!hasAbsCode(absBits, absCode)) return null;
  var rank = 0;
  for (var code = 0; code < absCode; code++) {
    if (hasAbsCode(absBits, code)) rank++;
  }
  return rank;
}
