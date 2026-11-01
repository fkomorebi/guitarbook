import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'gamepad_trigger.dart';
import 'linux_evdev.dart';
import 'linux_evdev_io.dart';

/// 通过 Linux evdev 读取手柄线性扳机。
///
/// 设备发现依赖 `/proc/bus/input/devices`；读取放在独立 isolate 里做非阻塞
/// `open` + `poll`（每次最多等 100 毫秒），避免阻塞 UI isolate，也让停用时
/// 能在 100 毫秒内退出。扳机轴量程通过 `EVIOCGABS` ioctl 读取（各驱动可能
/// 不同）。支持热插拔：设备断开会重新查找；找不到设备时每 2 秒重试。
class LinuxGamepadTriggerSource implements GamepadTriggerSource {
  LinuxGamepadTriggerSource({
    this.procDevicesPath = '/proc/bus/input/devices',
    this.devInputDirectory = '/dev/input',
  });

  final String procDevicesPath;
  final String devInputDirectory;

  final StreamController<GamepadSnapshot> _snapshots =
      StreamController<GamepadSnapshot>.broadcast();
  late final GamepadSnapshotEmitter _emitter = GamepadSnapshotEmitter(
    _snapshots,
  );

  PedalTrigger _trigger = PedalTrigger.right;
  bool _running = false;
  Future<void>? _loop;
  Completer<void>? _sleep;
  Isolate? _worker;
  SendPort? _workerCommands;
  int? _axisMinimum;
  int? _axisMaximum;

  @override
  bool get supported => true;

  @override
  String? get platformNote =>
      'Linux 直接读取 /dev/input/event*。多数桌面发行版会为已登录用户自动授权；'
      '若提示权限不足，可把当前用户加入 input 组。';

  @override
  Stream<GamepadSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start(PedalTrigger trigger) async {
    if (_running) return;
    _trigger = trigger;
    _running = true;
    _loop = _run();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _wake();
    _workerCommands?.send('stop');
    await _loop;
    _loop = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
  }

  Future<void> _run() async {
    while (_running) {
      final device = await _findDevice();
      if (!_running) break;
      if (device == null) {
        _emitter.emit(const GamepadSnapshot.searching());
        await _sleepFor(const Duration(seconds: 2));
        continue;
      }
      final axisCode = resolveTriggerAxis(device.absBits, _trigger);
      if (axisCode == null) {
        _emitter.emit(
          GamepadSnapshot(
            status: GamepadInputStatus.error,
            deviceName: device.name,
            error:
                '手柄“${device.name}”没有可用的线性扳机轴'
                '（例如 Switch Pro 的 ZL/ZR 是数字按键，不是线性扳机）。',
          ),
        );
        await _sleepFor(const Duration(seconds: 2));
        continue;
      }
      await _readDevice(device, axisCode);
      if (_running) await _sleepFor(const Duration(seconds: 1));
    }
  }

  Future<void> _readDevice(EvdevDevice device, int axisCode) async {
    final path = '$devInputDirectory/${device.eventHandler}';
    final results = ReceivePort();
    final closed = Completer<void>();
    _workerCommands = null;
    _axisMinimum = null;
    _axisMaximum = null;

    final subscription = results.listen((message) {
      final map = message as Map<String, Object?>;
      switch (map['type']) {
        case 'commands':
          final commands = map['port'] as SendPort;
          _workerCommands = commands;
          if (!_running) commands.send('stop');
        case 'ready':
          _axisMinimum = map['min'] as int?;
          _axisMaximum = map['max'] as int?;
          _emitter.emit(
            GamepadSnapshot(
              status: GamepadInputStatus.ready,
              deviceName: device.name,
              rawMin: _axisMinimum,
              rawMax: _axisMaximum,
            ),
          );
        case 'value':
          _emitter.emit(
            GamepadSnapshot(
              status: GamepadInputStatus.ready,
              deviceName: device.name,
              rawValue: map['raw'] as int,
              rawMin: _axisMinimum,
              rawMax: _axisMaximum,
            ),
          );
        case 'disconnected':
          _emitter.emit(
            GamepadSnapshot(
              status: GamepadInputStatus.searching,
              deviceName: device.name,
              error: '手柄已断开，正在重新查找…',
            ),
          );
        case 'openError':
          if (_running) {
            _emitter.emit(
              GamepadSnapshot(
                status: GamepadInputStatus.error,
                deviceName: device.name,
                error: _describeOpenError(map['code'] as int, path),
              ),
            );
          }
        case 'stopped':
          if (!closed.isCompleted) closed.complete();
      }
    });

    try {
      final isolate = await Isolate.spawn(_readTriggerIsolate, <Object?>[
        results.sendPort,
        path,
        axisCode,
      ]);
      _worker = isolate;
      if (!_running) _workerCommands?.send('stop');
      await closed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    } finally {
      await subscription.cancel();
      results.close();
      _workerCommands = null;
      final worker = _worker;
      _worker = null;
      worker?.kill(priority: Isolate.beforeNextEvent);
    }
  }

  String _describeOpenError(int errorCode, String path) {
    if (errorCode == 13) {
      return '没有权限读取 $path：请把当前用户加入 input 组'
          '（sudo usermod -aG input \$USER，然后重新登录），或为手柄添加 udev 规则。';
    }
    if (errorCode == 2) return '手柄输入设备 $path 已移除，正在重新查找…';
    return '无法打开手柄输入设备 $path（errno $errorCode）。';
  }

  Future<EvdevDevice?> _findDevice() async {
    try {
      final text = await File(procDevicesPath).readAsString();
      for (final device in parseProcInputDevices(text)) {
        if (resolveTriggerAxis(device.absBits, _trigger) != null) return device;
      }
      return null;
    } on FileSystemException catch (error) {
      _emitter.emit(
        GamepadSnapshot(
          status: GamepadInputStatus.error,
          error:
              '无法读取 $procDevicesPath：${error.message}。'
              '容器或虚拟机中可能没有输入设备。',
        ),
      );
      return null;
    }
  }

  /// 可被 [stop] 提前唤醒的延时。
  Future<void> _sleepFor(Duration duration) async {
    final completer = Completer<void>();
    _sleep = completer;
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    timer.cancel();
    if (identical(_sleep, completer)) _sleep = null;
  }

  void _wake() {
    final sleep = _sleep;
    _sleep = null;
    if (sleep != null && !sleep.isCompleted) sleep.complete();
  }
}

/// 在独立 isolate 中等待并读取 evdev 事件，把结果发回主 isolate。
Future<void> _readTriggerIsolate(List<Object?> args) async {
  final results = args[0] as SendPort;
  final path = args[1] as String;
  final axisCode = args[2] as int;

  final commands = ReceivePort();
  final io = LinuxEvdevIo();
  var stop = false;
  commands.listen((message) {
    if (message == 'stop') stop = true;
  });
  results.send(<String, Object?>{
    'type': 'commands',
    'port': commands.sendPort,
  });

  final opened = io.open(path);
  if (!opened.isOpen) {
    results.send(<String, Object?>{
      'type': 'openError',
      'code': opened.errorCode,
    });
    io.dispose();
    commands.close();
    results.send(<String, Object?>{'type': 'stopped'});
    return;
  }

  final fd = opened.fd;
  final range = io.absRange(fd, axisCode);
  results.send(<String, Object?>{
    'type': 'ready',
    'min': range?.minimum,
    'max': range?.maximum,
  });

  final buffer = EvdevEventBuffer();
  try {
    while (true) {
      if (stop) break;
      final revents = io.poll(fd, const Duration(milliseconds: 100));
      if (stop) break;
      if (revents < 0 || (revents & (pollErr | pollHup | pollNval)) != 0) {
        results.send(<String, Object?>{'type': 'disconnected'});
        break;
      }
      if (revents == 0) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      final chunk = io.read(fd, evdevEventSize * 64);
      if (stop) break;
      // 非阻塞读返回 0 字节说明设备已被移除（evdev 正常不会读到 EOF）。
      if (chunk == null || chunk.isEmpty) {
        results.send(<String, Object?>{'type': 'disconnected'});
        break;
      }
      for (final event in buffer.add(chunk)) {
        if (event.type != evAbs || event.code != axisCode) continue;
        results.send(<String, Object?>{'type': 'value', 'raw': event.value});
      }
      // 让 stop 消息有机会被处理。
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    io.close(fd);
    io.dispose();
    commands.close();
    results.send(<String, Object?>{'type': 'stopped'});
  }
}
