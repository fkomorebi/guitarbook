// 手柄输入诊断脚本：把「为什么找不到手柄」一次性打印清楚。
//
// 用法（在桌面上直接跑，不要在容器 / 沙箱里跑）：
//
//   build/flutter-sdk/bin/dart run tool/probe_gamepad.dart
//   build/flutter-sdk/bin/dart run tool/probe_gamepad.dart 10   # 抓 10 秒事件
//
// 输出内容：
//  1. 当前用户与所属组（判断是否在 input 组）；
//  2. 系统枚举到的全部输入设备，以及哪些带线性扳机轴；
//  3. 对应 /dev/input/event* 节点是否存在、权限是谁、ACL 有没有给当前用户授权、
//     能不能真的打开（打开失败会打印 errno 与含义）；
//  4. 内核注册的旧版 joystick 节点 /dev/input/js* 的权限与可打开性；
//  5. 扳机轴的 EVIOCGABS 量程 + 实时 ABS 事件（抓取期间挤压扳机即可看到数值）；
//  6. 用真实的 LinuxGamepadTriggerSource 跑几秒，打印它给出的状态。
import 'dart:async';
import 'dart:io';

import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev_io.dart';
import 'package:guitarbook/features/expression_pedal/linux_joystick.dart';
import 'package:guitarbook/features/expression_pedal/linux_gamepad_trigger_source.dart';

const String procDevicesPath = '/proc/bus/input/devices';
const String devInputDirectory = '/dev/input';

String _describeErrno(int code) {
  switch (code) {
    case 1:
      return 'EPERM 操作不被允许';
    case 2:
      return 'ENOENT 设备节点不存在（设备没插上或没被系统枚举）';
    case 13:
      return 'EACCES 权限不足（当前用户读不了这个设备节点）';
    case 19:
      return 'ENODEV 设备不存在（已经从系统移除）';
    case 16:
      return 'EBUSY 设备被占用';
    default:
      return 'errno $code';
  }
}

String _axisName(int code) {
  const names = <int, String>{
    0x00: 'ABS_X',
    0x01: 'ABS_Y',
    0x02: 'ABS_Z',
    0x03: 'ABS_RX',
    0x04: 'ABS_RY',
    0x05: 'ABS_RZ',
    0x06: 'ABS_THROTTLE',
    0x07: 'ABS_RUDDER',
    0x08: 'ABS_WHEEL',
    0x09: 'ABS_GAS',
    0x0a: 'ABS_BRAKE',
    0x10: 'ABS_HAT0X',
    0x11: 'ABS_HAT0Y',
    0x14: 'ABS_HAT2X',
    0x15: 'ABS_HAT2Y',
  };
  return names[code] ?? 'ABS_$code';
}

Future<String> _statLine(String path) async {
  try {
    final result = await Process.run('stat', ['-c', '%A %U:%G', path]);
    final out = (result.stdout as String).trim();
    if (result.exitCode != 0 || out.isEmpty) return '存在（stat 失败）';
    return out;
  } catch (_) {
    return '存在';
  }
}

/// 打印 ACL（谁被授权读写这个节点）。
Future<void> _printAcl(String path) async {
  try {
    final result = await Process.run('getfacl', ['-p', path]);
    final text = (result.stdout as String).trim();
    if (result.exitCode != 0 || text.isEmpty) {
      stdout.writeln('    ACL：读取失败（getfacl 不可用或没有权限）');
      return;
    }
    final lines = text
        .split('\n')
        .where((line) =>
            line.contains('user:') || line.contains('group:') || line.contains('mask:'))
        .map((line) => line.trim())
        .toList();
    if (lines.isEmpty) {
      stdout.writeln('    ACL：没有额外授权（只有属主/属组权限）');
    } else {
      for (final line in lines) {
        stdout.writeln('    ACL：$line');
      }
    }
  } catch (_) {
    stdout.writeln('    ACL：读取失败（getfacl 不可用）');
  }
}

/// 打开手柄的事件节点，读取扳机轴量程，并实时打印 ABS 事件。
Future<void> _captureLiveEvents(EvdevDevice device, int seconds) async {
  final io = LinuxEvdevIo();
  final path = '$devInputDirectory/${device.eventHandler}';
  final opened = io.open(path);
  if (!opened.isOpen) {
    stdout.writeln('  打开 $path 失败：${_describeErrno(opened.errorCode)}');
    io.dispose();
    return;
  }
  final fd = opened.fd;
  stdout.writeln('  已打开 $path ✓（接下来 $seconds 秒内请挤压右扳机 / L2）');
  for (final axis in const [absZ, absRz, absGas, absBrake]) {
    final range = io.absRange(fd, axis);
    stdout.writeln('    量程 ${_axisName(axis)}：'
        '${range == null ? '读取失败（EVIOCGABS 无返回）' : '${range.minimum} .. ${range.maximum}'}');
  }
  final buffer = EvdevEventBuffer();
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  var events = 0;
  while (DateTime.now().isBefore(deadline)) {
    final revents = io.poll(fd, const Duration(milliseconds: 100));
    if (revents < 0) {
      stdout.writeln('  poll 失败');
      break;
    }
    if ((revents & (pollErr | pollHup | pollNval)) != 0) {
      stdout.writeln('  设备已断开（poll 返回异常）');
      break;
    }
    if (revents == 0) continue;
    final chunk = io.read(fd, evdevEventSize * 64);
    if (chunk == null || chunk.isEmpty) {
      stdout.writeln('  读到 EOF（设备已被移除）');
      break;
    }
    for (final event in buffer.add(chunk)) {
      if (event.type != evAbs) continue;
      events++;
      stdout.writeln('    事件 ABS ${_axisName(event.code)} (code ${event.code}) = ${event.value}');
    }
  }
  stdout.writeln('  抓取结束，共 $events 条 ABS 事件。');
  io.close(fd);
  io.dispose();
}

/// 打开旧版 joystick 节点，打印扳机轴映射，并实时打印换算后的扳机读数。
Future<void> _captureJoystickEvents(
  String path,
  int? axisCode,
  int seconds,
) async {
  final io = LinuxEvdevIo();
  final opened = io.open(path);
  if (!opened.isOpen) {
    stdout.writeln('  打开 $path 失败：${_describeErrno(opened.errorCode)}');
    io.dispose();
    return;
  }
  final fd = opened.fd;
  stdout.writeln('  已打开 $path ✓（旧版接口，任何用户都能读）');
  final axisMap = io.jsAxisMap(fd);
  if (axisMap == null) {
    stdout.writeln('    JSIOCGAXMAP 读取失败');
  } else {
    final used = axisMap.take(12).toList();
    stdout.writeln('    JSIOCGAXMAP 前 ${used.length} 项（旧版轴号 → ABS 编码）：$used');
  }
  final axisIndex = axisCode == null
      ? null
      : (axisMap == null ? null : jsAxisIndexFor(axisMap, axisCode));
  stdout.writeln('    右扳机 ABS 编码 $axisCode → 旧版轴号 ${axisIndex ?? '未知'}');
  final buffer = JsEventBuffer();
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  var events = 0;
  while (DateTime.now().isBefore(deadline)) {
    final revents = io.poll(fd, const Duration(milliseconds: 100));
    if (revents < 0 || (revents & (pollErr | pollHup | pollNval)) != 0) {
      stdout.writeln('    设备已断开');
      break;
    }
    if (revents == 0) continue;
    final chunk = io.read(fd, jsEventSize * 64);
    if (chunk == null || chunk.isEmpty) {
      stdout.writeln('    读到 EOF（设备已被移除）');
      break;
    }
    for (final event in buffer.add(chunk)) {
      if (!event.isAxis) continue;
      events++;
      stdout.writeln(
        '    轴 ${event.number}（${event.isInit ? '初始值' : '变化'}）：'
        '${event.value} → 扳机读数 ${jsTriggerRaw(event.value)}',
      );
    }
  }
  stdout.writeln('  抓取结束，共 $events 条轴事件。');
  io.close(fd);
  io.dispose();
}

Future<void> _main(List<String> args) async {
  final seconds = args.isEmpty ? 8 : (int.tryParse(args.first) ?? 8);

  stdout.writeln('===== 1. 当前用户 =====');
  stdout.writeln('uid=${Process.runSync('id', ['-u']).stdout.toString().trim()} '
      'groups=${Process.runSync('id', ['-G']).stdout.toString().trim()}');
  stdout.writeln('提示：/dev/input/event* 默认是 root:input 0660，'
      '要么把用户加入 input 组，要么用 udev 规则给当前会话授权（uaccess）。');
  stdout.writeln('');

  stdout.writeln('===== 2. 系统输入设备 =====');
  String procText;
  try {
    procText = await File(procDevicesPath).readAsString();
  } catch (error) {
    stdout.writeln('读取 $procDevicesPath 失败：$error');
    stdout.writeln('（容器、快照或受限沙箱里读不到宿主机的输入设备列表）');
    return;
  }
  final devices = parseProcInputDevices(procText);
  stdout.writeln('共 ${devices.length} 个带事件节点的输入设备：');
  EvdevDevice? gamepad;
  for (final device in devices) {
    final left = resolveTriggerAxis(device.absBits, PedalTrigger.left);
    final right = resolveTriggerAxis(device.absBits, PedalTrigger.right);
    final tag = left != null || right != null
        ? '← 有线性扳机轴（左 $left / 右 $right）'
        : '';
    stdout.writeln('  ${device.name}  '
        'event=${device.eventHandler} '
        'js=${device.joystickHandler ?? '-'} '
        'abs=0x${device.absBits.toRadixString(16)} $tag');
    if (left != null || right != null) gamepad ??= device;
  }
  stdout.writeln('');

  stdout.writeln('===== 3. 事件节点权限 / ACL / 可打开性 =====');
  final io = LinuxEvdevIo();
  for (final device in devices) {
    final path = '$devInputDirectory/${device.eventHandler}';
    final exists = File(path).existsSync();
    if (!exists) {
      stdout.writeln('  $path  不存在（设备已移除或系统没有创建节点）');
      continue;
    }
    final perm = await _statLine(path);
    final opened = io.open(path);
    if (opened.isOpen) {
      io.close(opened.fd);
      stdout.writeln('  $path  $perm  → 可以打开 ✓');
      await _printAcl(path);
    } else {
      stdout.writeln('  $path  $perm  → 打开失败：${_describeErrno(opened.errorCode)}');
      await _printAcl(path);
    }
  }
  stdout.writeln('');

  stdout.writeln('===== 4. 旧版 joystick 节点（Ubuntu 默认 0664，常常无需任何权限） =====');
  List<String> jsNodes = const [];
  if (!Directory(devInputDirectory).existsSync()) {
    stdout.writeln('  $devInputDirectory 目录不存在（容器 / 沙箱里没有输入设备节点）');
  } else {
    jsNodes = Directory(devInputDirectory)
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split('/').last)
        .where((name) => name.startsWith('js'))
        .toList()
      ..sort();
  }
  if (jsNodes.isEmpty) {
    stdout.writeln('  没有 /dev/input/js* 节点（内核没有注册旧版 joystick 设备）');
  } else {
    for (final node in jsNodes) {
      final path = '$devInputDirectory/$node';
      final perm = await _statLine(path);
      final opened = io.open(path);
      if (opened.isOpen) {
        io.close(opened.fd);
        stdout.writeln('  $path  $perm  → 可以打开 ✓');
      } else {
        stdout.writeln('  $path  $perm  → 打开失败：${_describeErrno(opened.errorCode)}');
      }
    }
  }
  stdout.writeln('');

  stdout.writeln('===== 5. 扳机轴量程与实时事件 =====');
  if (gamepad == null) {
    stdout.writeln('  系统里没有带线性扳机轴的设备，跳过。');
  } else {
    stdout.writeln('  目标设备：${gamepad.name}（${gamepad.eventHandler}）');
    await _captureLiveEvents(gamepad, seconds);
  }
  stdout.writeln('');

  stdout.writeln('===== 6. 旧版 joystick 通道（不需要 input 组权限） =====');
  final jsHandler = gamepad?.joystickHandler;
  if (gamepad == null || jsHandler == null) {
    stdout.writeln('  这只手柄没有 /dev/input/js* 节点，只能走 evdev。');
  } else {
    await _captureJoystickEvents(
      '$devInputDirectory/$jsHandler',
      resolveTriggerAxis(gamepad.absBits, PedalTrigger.right),
      seconds,
    );
  }
  stdout.writeln('');

  stdout.writeln('===== 7. 真实输入源的状态（跑 3 秒） =====');
  final source = LinuxGamepadTriggerSource();
  final subscription = source.snapshots.listen((snapshot) {
    stdout.writeln('  status=${snapshot.status.name} '
        'device=${snapshot.deviceName ?? '-'} '
        'raw=${snapshot.rawValue ?? '-'} '
        'range=${snapshot.rawMin ?? '-'}-${snapshot.rawMax ?? '-'} '
        'error=${snapshot.error ?? '-'}');
  });
  await source.start(PedalTrigger.right);
  await Future<void>.delayed(const Duration(seconds: 3));
  await source.stop();
  await subscription.cancel();
  await source.dispose();
  stdout.writeln('');
  stdout.writeln('提示：网页端走浏览器 Gamepad API，'
      '在 Linux 上浏览器同样需要能读 /dev/input/event*（Chrome 官方 udev 规则缺失时也会看不到手柄）。');
}

Future<void> main(List<String> args) async {
  try {
    await _main(args);
  } catch (error, stack) {
    stderr.writeln('诊断脚本出错：$error');
    stderr.writeln(stack);
    exitCode = 1;
  }
}
