import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';
import 'package:guitarbook/features/expression_pedal/linux_gamepad_trigger_source.dart';
import 'package:guitarbook/features/expression_pedal/linux_joystick.dart';

const _procText = '''I: Bus=0003 Vendor=045e Product=02ea Version=0408
N: Name="Fake Pad"
H: Handlers=event9 js0 
B: ABS=3f

''';

void main() {
  test('从模拟的事件节点读到扳机数值', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString(_procText);
    await File(
      '${directory.path}/event9',
    ).writeAsBytes(eventBytes(evAbs, absZ, 512));

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.left);
    await _waitUntil(
      () => snapshots.any((snapshot) => snapshot.rawValue == 512),
    );
    final value = snapshots.firstWhere((snapshot) => snapshot.rawValue == 512);
    expect(value.status, GamepadInputStatus.ready);
    expect(value.deviceName, 'Fake Pad');
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('设备节点打不开时报告错误', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString(_procText);

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.left);
    await _waitUntil(
      () => snapshots.any(
        (snapshot) =>
            snapshot.status == GamepadInputStatus.error &&
            (snapshot.error?.contains('已移除') ?? false),
      ),
    );
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('找不到手柄时进入查找状态', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString(
      'N: Name="Keyboard"\nH: Handlers=event2 \nB: ABS=0\n\n',
    );

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.left);
    await _waitUntil(
      () => snapshots.any(
        (snapshot) => snapshot.status == GamepadInputStatus.searching,
      ),
    );
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('读不到设备列表时报告错误，不会退化成“正在查找手柄…”', () async {
    if (!Platform.isLinux) return;
    final source = LinuxGamepadTriggerSource(
      procDevicesPath: '/nonexistent/guitarbook-input-devices',
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.right);
    await _waitUntil(
      () => snapshots.any(
        (snapshot) => snapshot.status == GamepadInputStatus.error,
      ),
    );
    // 回归点：错误文案不能被随后发出的“正在查找手柄…”覆盖掉。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(snapshots.last.status, GamepadInputStatus.error);
    expect(snapshots.last.error, contains('无法读取'));
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('手柄在线但没有线性扳机轴时点名提示', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString('''
N: Name="Nintendo Switch Pro Controller"
H: Handlers=event9 js0
B: ABS=3000B

''');

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.right);
    await _waitUntil(
      () => snapshots.any(
        (snapshot) => snapshot.status == GamepadInputStatus.error,
      ),
    );
    expect(snapshots.last.error, contains('Nintendo Switch Pro Controller'));
    expect(snapshots.last.error, contains('线性扳机'));
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('只带 XY 轴的触控板不会被当成没有扳机轴的手柄', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString('''
N: Name="QEMU QEMU USB Tablet"
H: Handlers=event5 js0
B: ABS=3

''');

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.right);
    await _waitUntil(
      () => snapshots.any(
        (snapshot) => snapshot.status == GamepadInputStatus.searching,
      ),
    );
    // 触控板不是手柄：提示里只应该说扫描到几个设备，不该点名说它没有扳机轴。
    expect(snapshots.last.error, contains('1 个输入设备'));
    expect(snapshots.last.error, isNot(contains('QEMU')));
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('找不到手柄时说明扫描到了多少输入设备', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString('''
N: Name="AT Translated Set 2 keyboard"
H: Handlers=event1
B: ABS=0

N: Name="VMware VMware Virtual Mouse"
H: Handlers=event2 mouse0
B: ABS=0

''');

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.right);
    await _waitUntil(
      () => snapshots.any(
        (snapshot) => snapshot.status == GamepadInputStatus.searching,
      ),
    );
    expect(snapshots.last.error, contains('2 个输入设备'));
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('event 节点没有读权限时自动改读旧版 joystick 节点', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_src_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final procFile = File('${directory.path}/devices');
    await procFile.writeAsString(_procText);
    // event9 存在但没有读权限，模拟 /dev/input/event* 默认 0660 root:input。
    final eventFile = File('${directory.path}/event9');
    await eventFile.writeAsBytes(eventBytes(evAbs, absZ, 512));
    await Process.run('chmod', ['000', eventFile.path]);
    // js0 是 0664 免权限通道：内核给旧版接口的是 8 字节 js_event，
    // ABS_Z 在这台假手柄上的旧版轴号是 2（X、Y、Z 依次编号）。
    await File('${directory.path}/js0').writeAsBytes(
      jsEventBytes(value: 0, type: jsEventAxis, number: 2),
    );

    final source = LinuxGamepadTriggerSource(
      procDevicesPath: procFile.path,
      devInputDirectory: directory.path,
    );
    addTearDown(source.dispose);
    final snapshots = <GamepadSnapshot>[];
    final subscription = source.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await source.start(PedalTrigger.left);
    await _waitUntil(
      () => snapshots.any((snapshot) => snapshot.rawValue == 128),
    );
    final value = snapshots.firstWhere(
      (snapshot) => snapshot.rawValue == 128,
    );
    expect(value.status, GamepadInputStatus.ready);
    expect(value.deviceName, 'Fake Pad');
    // 旧版接口的值是 -32767..32767，中点 0 换算成 0–255 的中值。
    expect(value.rawMin, jsTriggerRawMinimum);
    expect(value.rawMax, jsTriggerRawMaximum);
    await source.stop();
  }, timeout: const Timeout(Duration(seconds: 20)));
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待手柄读数超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 按 64 位 Linux 的 `struct input_event` 布局生成一条事件。
List<int> eventBytes(int type, int code, int value) {
  final data = ByteData(evdevEventSize);
  data.setUint16(16, type, Endian.host);
  data.setUint16(18, code, Endian.host);
  data.setInt32(20, value, Endian.host);
  return data.buffer.asUint8List();
}

/// 按 8 字节 `struct js_event` 布局生成一条旧版 joystick 事件。
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
