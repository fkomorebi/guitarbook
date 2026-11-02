import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';
import 'package:guitarbook/features/expression_pedal/linux_joystick.dart';

/// 拼一条 `struct js_event`：`__u32 time`、`__s16 value`、`__u8 type`、
/// `__u8 number`。
List<int> jsEventBytes({
  int time = 0,
  required int value,
  required int type,
  required int number,
}) {
  final data = ByteData(jsEventSize);
  data.setUint32(0, time, Endian.host);
  data.setInt16(4, value, Endian.host);
  data.setUint8(6, type);
  data.setUint8(7, number);
  return data.buffer.asUint8List();
}

void main() {
  group('JSIOCGAXMAP 请求码', () {
    test('按 _IOR(\'j\', 0x32, __u8[64]) 计算', () {
      expect(jsIoctlGetAxisMap, 0x80406a32);
    });
  });

  group('JsEventBuffer', () {
    test('解析一条轴事件', () {
      final buffer = JsEventBuffer();
      final events = buffer.add(
        jsEventBytes(time: 12345, value: -32767, type: jsEventAxis, number: 5),
      );
      expect(events, hasLength(1));
      expect(events.single.time, 12345);
      expect(events.single.value, -32767);
      expect(events.single.type, jsEventAxis);
      expect(events.single.number, 5);
      expect(events.single.isAxis, isTrue);
      expect(events.single.isInit, isFalse);
    });

    test('不完整的尾部留到下一块', () {
      final buffer = JsEventBuffer();
      final bytes = jsEventBytes(value: 12000, type: jsEventAxis, number: 2);
      expect(buffer.add(bytes.sublist(0, 5)), isEmpty);
      final events = buffer.add(bytes.sublist(5));
      expect(events, hasLength(1));
      expect(events.single.value, 12000);
      expect(events.single.number, 2);
    });

    test('一个块里有多条事件时按顺序解析', () {
      final buffer = JsEventBuffer();
      final bytes = <int>[
        ...jsEventBytes(value: -32767, type: jsEventAxis, number: 5),
        ...jsEventBytes(value: 0, type: jsEventAxis, number: 5),
        ...jsEventBytes(value: 1, type: jsEventButton, number: 0),
      ];
      final events = buffer.add(bytes);
      expect(events.map((event) => event.value), [-32767, 0, 1]);
      expect(events.map((event) => event.number), [5, 5, 0]);
    });

    test('打开设备时的初始化事件也带 JS_EVENT_INIT 位', () {
      final buffer = JsEventBuffer();
      final events = buffer.add(
        jsEventBytes(
          value: -32767,
          type: jsEventAxis | jsEventInit,
          number: 5,
        ),
      );
      expect(events.single.isAxis, isTrue, reason: '去掉 INIT 位后仍是轴事件');
      expect(events.single.isInit, isTrue);
      expect(events.single.kind, jsEventAxis);
    });

    test('重置后丢弃残留字节', () {
      final buffer = JsEventBuffer();
      buffer.add(const [1, 2, 3]);
      buffer.reset();
      final events = buffer.add(
        jsEventBytes(value: 255, type: jsEventAxis, number: 5),
      );
      expect(events, hasLength(1));
      expect(events.single.value, 255);
    });
  });

  group('jsTriggerRaw', () {
    test('松开与按到底分别对应 0 和 255', () {
      expect(jsTriggerRaw(jsValueMinimum), 0);
      expect(jsTriggerRaw(jsValueMaximum), 255);
    });

    test('中点是 128', () {
      expect(jsTriggerRaw(0), 128);
    });

    test('超出范围的原始值会被夹紧', () {
      expect(jsTriggerRaw(-40000), 0);
      expect(jsTriggerRaw(40000), 255);
    });

    test('单调不减', () {
      var previous = -1;
      for (var value = jsValueMinimum; value <= jsValueMaximum; value += 777) {
        final raw = jsTriggerRaw(value);
        expect(raw, greaterThanOrEqualTo(previous));
        expect(raw, inInclusiveRange(jsTriggerRawMinimum, jsTriggerRawMaximum));
        previous = raw;
      }
    });
  });

  group('旧版轴号定位', () {
    // xpad 上报 ABS_X/Y/Z/RX/RY/RZ + HAT0X/HAT0Y，joydev 按编码升序编号：
    // 0=ABS_X、1=ABS_Y、2=ABS_Z、3=ABS_RX、4=ABS_RY、5=ABS_RZ、6=HAT0X、
    // 7=HAT0Y。
    final axisMap = <int>[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11];

    test('JSIOCGAXMAP 的表直接把 ABS 编码映射成旧版轴号', () {
      expect(jsAxisIndexFor(axisMap, absZ), 2);
      expect(jsAxisIndexFor(axisMap, absRz), 5);
      expect(jsAxisIndexFor(axisMap, 0x10), 6);
    });

    test('表里没有这个轴时返回 null', () {
      expect(jsAxisIndexFor(axisMap, absGas), isNull);
      expect(jsAxisIndexFor(const [], absRz), isNull);
    });

    test('按位图推算的轴号与 joydev 的编号规则一致', () {
      final absBits = parseAbsBitmap('3003f');
      expect(jsAxisIndexFromBits(absBits, absZ), 2);
      expect(jsAxisIndexFromBits(absBits, absRz), 5);
      expect(jsAxisIndexFromBits(absBits, 0x10), 6);
      expect(jsAxisIndexFromBits(absBits, 0x11), 7);
    });

    test('位图里没有的轴返回 null', () {
      expect(jsAxisIndexFromBits(parseAbsBitmap('3003f'), absGas), isNull);
    });

    test('额外上报油门/刹车轴时编号会顺延', () {
      // ABS_X/Y/Z/RX/RY/RZ/THROTTLE/RUDDER/WHEEL/GAS/BRAKE + HAT0X/HAT0Y
      final absBits = parseAbsBitmap('307ff');
      expect(jsAxisIndexFromBits(absBits, absZ), 2);
      expect(jsAxisIndexFromBits(absBits, 0x06), 6); // ABS_THROTTLE
      expect(jsAxisIndexFromBits(absBits, 0x08), 8); // ABS_WHEEL
      expect(jsAxisIndexFromBits(absBits, absGas), 9); // ABS_GAS
      expect(jsAxisIndexFromBits(absBits, absBrake), 10); // ABS_BRAKE
      expect(jsAxisIndexFromBits(absBits, 0x10), 11); // ABS_HAT0X
    });
  });
}
