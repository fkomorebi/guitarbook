import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';
import 'package:guitarbook/features/expression_pedal/linux_gamepad_trigger_source.dart';

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
