import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';

const _procSample = '''I: Bus=0003 Vendor=045e Product=02ea Version=0408
N: Name="Microsoft X-Box One pad"
P: Phys=usb-0000:00:14.0-1/input0
S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/input/input20
U: Uniq=
H: Handlers=event5 js0 
B: PROP=0
B: EV=20000b
B: KEY=7cdb000000000000 0 0 0 0
B: ABS=3003f

I: Bus=0018 Vendor=04f3 Product=2d4e Version=0100
N: Name="ELAN Touchscreen"
P: Phys=
S: Sysfs=/devices/platform/i2c-designware/i2c-0/0018:04f3:2d4e.0001/input/input3
U: Uniq=
H: Handlers=event3 
B: PROP=2
B: EV=b
B: KEY=400 0 0 0 0 0
B: ABS=2608000 1000003

I: Bus=0003 Vendor=046d Product=c31c Version=0110
N: Name="Logitech USB Keyboard"
P: Phys=usb-0000:00:14.0-3/input0
S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-3/1-3:1.0/input/input7
U: Uniq=
H: Handlers=sysrq kbd event2 leds 
B: PROP=0
B: EV=120013
B: KEY=1000000000007 ff9f207a c14057ff febeffdf ffefffff ffffffff fffffffe
B: ABS=0
''';

void main() {
  group('parseProcInputDevices', () {
    test('解析出带 event 节点的设备，保留名称与 ABS 位图', () {
      final devices = parseProcInputDevices(_procSample);
      expect(devices.map((device) => device.name), [
        'Microsoft X-Box One pad',
        'ELAN Touchscreen',
        'Logitech USB Keyboard',
      ]);
      expect(devices.map((device) => device.eventHandler), [
        'event5',
        'event3',
        'event2',
      ]);
      expect(devices.first.absBits, parseAbsBitmap('3003f'));
    });

    test('只认带 ABS_Z / ABS_RZ 等扳机轴的手柄', () {
      final devices = parseProcInputDevices(_procSample);
      expect(supportsAnalogTrigger(devices[0].absBits), isTrue);
      expect(supportsAnalogTrigger(devices[1].absBits), isFalse);
      expect(supportsAnalogTrigger(devices[2].absBits), isFalse);
    });

    test('左右扳机分别解析为 ABS_Z 与 ABS_RZ', () {
      final bits = parseAbsBitmap('3003f');
      expect(resolveTriggerAxis(bits, PedalTrigger.left), absZ);
      expect(resolveTriggerAxis(bits, PedalTrigger.right), absRz);
    });

    test('没有手柄轴时返回 null', () {
      final bits = parseAbsBitmap('0');
      expect(resolveTriggerAxis(bits, PedalTrigger.left), isNull);
      expect(resolveTriggerAxis(bits, PedalTrigger.right), isNull);
    });

    test('只有 ABS_GAS / ABS_BRAKE 的驱动回退到通用油门/刹车轴', () {
      final bits = parseAbsBitmap('600');
      expect(resolveTriggerAxis(bits, PedalTrigger.left), absBrake);
      expect(resolveTriggerAxis(bits, PedalTrigger.right), absGas);
    });

    test('ABS_HAT2X / ABS_HAT2Y 优先于其它扳机轴', () {
      final bits = parseAbsBitmap('300000');
      expect(resolveTriggerAxis(bits, PedalTrigger.left), absHat2Y);
      expect(resolveTriggerAxis(bits, PedalTrigger.right), absHat2X);
    });

    test('名称中的引号会被去掉', () {
      final devices = parseProcInputDevices(
        'N: Name="8BitDo Pro 2"\nH: Handlers=event9 \nB: ABS=3\n',
      );
      expect(devices.single.name, '8BitDo Pro 2');
    });

    test('缺少 ABS 行的设备不参与扳机匹配', () {
      final devices = parseProcInputDevices(
        'N: Name="No Abs Pad"\nH: Handlers=event1 \n',
      );
      expect(devices.single.absBits, BigInt.zero);
    });

    test('记录内核注册的 joystick 节点，用来识别数字按键式手柄', () {
      final devices = parseProcInputDevices(_procSample);
      expect(devices[0].eventHandler, 'event5');
      expect(devices[0].joystickHandler, 'js0');
      expect(devices[1].joystickHandler, isNull);
      expect(devices[2].joystickHandler, isNull);
    });

    test('Handlers 里只有 event 节点时没有 joystick 记录', () {
      final devices = parseProcInputDevices('''
N: Name="Plain Keyboard"
H: Handlers=event1
B: ABS=0
''');
      expect(devices.single.eventHandler, 'event1');
      expect(devices.single.joystickHandler, isNull);
    });
  });

  group('parseAbsBitmap', () {
    test('高位字在前，跨 32 位的位图也能解析', () {
      // 内核从高字到低字打印；'3 1000003' 的高字为 3（第 32、33 位），
      // 低字为 0x1000003（第 0、1、24 位）。
      final bits = parseAbsBitmap('3 1000003');
      expect(hasAbsCode(bits, 0), isTrue);
      expect(hasAbsCode(bits, 1), isTrue);
      expect(hasAbsCode(bits, 2), isFalse);
      expect(hasAbsCode(bits, 32), isTrue);
      expect(hasAbsCode(bits, 33), isTrue);
      expect(hasAbsCode(bits, 34), isFalse);
    });

    test('忽略多余空白', () {
      expect(parseAbsBitmap('  3  0  '), parseAbsBitmap('3 0'));
    });
  });

  group('EvdevEventBuffer', () {
    test('一个数据块里的多条事件全部解析', () {
      final buffer = EvdevEventBuffer();
      final chunk = [
        ...eventBytes(evAbs, absZ, 10),
        ...eventBytes(evAbs, absRz, 20),
        ...eventBytes(0x00, 0x00, 0),
      ];
      final events = buffer.add(chunk);
      expect(events.map((event) => event.code), [absZ, absRz, 0x00]);
      expect(events.map((event) => event.value), [10, 20, 0]);
    });

    test('被拆开的事件留到下一块拼接', () {
      final buffer = EvdevEventBuffer();
      final bytes = eventBytes(evAbs, absZ, 200);
      expect(buffer.add(bytes.sublist(0, 10)), isEmpty);
      final events = buffer.add(bytes.sublist(10));
      expect(events.single.value, 200);
    });

    test('尾部不足一条事件时先不解析，补齐后再解析', () {
      final buffer = EvdevEventBuffer();
      final first = eventBytes(evAbs, absZ, 1);
      final second = eventBytes(evAbs, absZ, 2);
      final events = buffer.add([...first, ...second.sublist(0, 12)]);
      expect(events.single.value, 1);
      expect(buffer.add(second.sublist(12)).single.value, 2);
    });

    test('reset 丢弃未完成的事件', () {
      final buffer = EvdevEventBuffer();
      buffer.add(eventBytes(evAbs, absZ, 1).sublist(0, 12));
      buffer.reset();
      final events = buffer.add(eventBytes(evAbs, absZ, 3));
      expect(events.single.value, 3);
    });

    test('按位读取事件类型、编码和 32 位有符号数值', () {
      final buffer = EvdevEventBuffer();
      final events = buffer.add(eventBytes(evKey, 0x132, -5));
      expect(events.single.type, evKey);
      expect(events.single.code, 0x132);
      expect(events.single.value, -5);
    });
  });
}

/// 按 64 位 Linux 的 `struct input_event` 布局生成一条事件。
List<int> eventBytes(int type, int code, int value) {
  final data = ByteData(evdevEventSize);
  data.setUint16(16, type, Endian.host);
  data.setUint16(18, code, Endian.host);
  data.setInt32(20, value, Endian.host);
  return data.buffer.asUint8List();
}
