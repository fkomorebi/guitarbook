import 'dart:typed_data';

/// `struct input_absinfo` 的字节数：
/// `__s32 value`、`__s32 minimum`、`__s32 maximum`、`__s32 fuzz`、
/// `__s32 flat`、`__s32 resolution`。
const int inputAbsInfoSize = 24;

/// 某个绝对轴的内核量程。
class AbsAxisRange {
  const AbsAxisRange(this.minimum, this.maximum);

  final int minimum;
  final int maximum;

  @override
  bool operator ==(Object other) =>
      other is AbsAxisRange &&
      other.minimum == minimum &&
      other.maximum == maximum;

  @override
  int get hashCode => Object.hash(minimum, maximum);

  @override
  String toString() => 'AbsAxisRange($minimum, $maximum)';
}

/// `EVIOCGABS(abs)` 的 ioctl 请求码，即 `_IOR('E', 0x40 + abs, struct
/// input_absinfo)`。Linux 上各驱动的扳机量程不同（0..255 或 0..1023 等），
/// 只有这个 ioctl 能拿到准确量程。
int absInfoRequest(int absCode) =>
    (2 << 30) |
    (inputAbsInfoSize << 16) |
    ('E'.codeUnitAt(0) << 8) |
    (0x40 + absCode);

/// 从 ioctl 填好的 `struct input_absinfo` 字节中解析量程。
AbsAxisRange? decodeAbsInfo(Uint8List bytes) {
  if (bytes.lengthInBytes < inputAbsInfoSize) return null;
  final data = ByteData.sublistView(bytes);
  final minimum = data.getInt32(4, Endian.host);
  final maximum = data.getInt32(8, Endian.host);
  if (maximum <= minimum) return null;
  return AbsAxisRange(minimum, maximum);
}
