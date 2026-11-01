import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/linux_abs_info.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';

void main() {
  test('ABS ioctl 请求码符合 _IOR 定义', () {
    expect(absInfoRequest(absZ), 0x80184542);
    expect(absInfoRequest(absRz), 0x80184545);
  });

  test('解析 input_absinfo 中的 minimum / maximum', () {
    final data = ByteData(inputAbsInfoSize)
      ..setInt32(0, 512, Endian.host)
      ..setInt32(4, 0, Endian.host)
      ..setInt32(8, 1023, Endian.host)
      ..setInt32(12, 4, Endian.host)
      ..setInt32(16, 0, Endian.host)
      ..setInt32(20, 0, Endian.host);
    expect(
      decodeAbsInfo(data.buffer.asUint8List()),
      const AbsAxisRange(0, 1023),
    );
  });

  test('最大值不大于最小值时视为无效量程', () {
    final data = ByteData(inputAbsInfoSize)
      ..setInt32(4, 100, Endian.host)
      ..setInt32(8, 100, Endian.host);
    expect(decodeAbsInfo(data.buffer.asUint8List()), isNull);
  });

  test('字节数不足时返回 null', () {
    expect(decodeAbsInfo(Uint8List(8)), isNull);
  });
}
