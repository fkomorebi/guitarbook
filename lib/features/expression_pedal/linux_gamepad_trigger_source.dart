import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'gamepad_trigger.dart';
import 'linux_evdev.dart';
import 'linux_evdev_io.dart';
import 'linux_joystick.dart';

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
      'Linux 直接读取 /dev/input/event*，该节点默认属于 root:input 组，'
      '所以当前用户需要额外的读取权限。两种办法任选其一（都需要管理员权限）：'
      '① 让当前桌面会话立刻获得权限（不用重新登录）：'
      'echo \'KERNEL=="event*", SUBSYSTEM=="input", MODE="0660", GROUP="input", '
      'TAG+="uaccess"\' | sudo tee /etc/udev/rules.d/99-gamepad.rules && '
      'sudo udevadm control --reload-rules && sudo udevadm trigger；'
      '② 把当前用户加入 input 组（需要重新登录）：'
      'sudo usermod -aG input \$USER。'
      '网页版走浏览器 Gamepad API，在 Linux 上浏览器同样需要读 /dev/input/event* '
      '的权限（Chrome 官方 udev 规则缺失时，浏览器也看不到手柄）。';

  @override
  Stream<GamepadSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start(PedalTrigger trigger) async {
    if (_running) return;
    _trigger = trigger;
    _running = true;
    // 新会话的第一条 ready 快照必须发出去；否则停用/切换扳机后重新启用时，
    // 去重会把它吞掉，界面会一直停在“正在查找手柄…”。
    _emitter.reset();
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
      try {
        final scan = await _findDevice();
        if (!_running) break;
        final device = scan.device;
        if (device == null) {
          _emitter.emit(_missingDeviceSnapshot(scan));
          await _sleepFor(const Duration(seconds: 2));
          continue;
        }
        final axisCode = resolveTriggerAxis(device.absBits, _trigger)!;
        await _readDevice(device, axisCode);
        if (_running) await _sleepFor(const Duration(seconds: 1));
      } catch (error) {
        // 读取过程中的意外异常不应该让整个循环停掉，否则界面会一直停在
        // “正在查找手柄…”而不给任何原因。
        if (!_running) break;
        _emitter.emit(
          GamepadSnapshot(
            status: GamepadInputStatus.error,
            error: '读取手柄时出错：$error',
          ),
        );
        await _sleepFor(const Duration(seconds: 2));
      }
    }
  }

  /// 没有找到带线性扳机轴的设备时，给出能区分原因的状态。
  ///
  /// - 读不到 `/proc` → 错误状态，保留具体原因（容器/沙箱里常见）。
  /// - 找到手柄但没有线性扳机轴 → 错误状态，点名是哪一台。
  /// - 什么都没有 → 查找状态，并说明扫描到了多少输入设备。
  GamepadSnapshot _missingDeviceSnapshot(_DeviceScan scan) {
    final error = scan.error;
    if (error != null) {
      return GamepadSnapshot(status: GamepadInputStatus.error, error: error);
    }
    if (scan.joystickNames.isNotEmpty) {
      return GamepadSnapshot(
        status: GamepadInputStatus.error,
        error:
            '检测到手柄“${scan.joystickNames.join('、')}”，但它没有可用的线性扳机轴'
            '（例如 Switch Pro 的 ZL/ZR 是数字按键，不是线性扳机）。',
      );
    }
    return GamepadSnapshot(
      status: GamepadInputStatus.searching,
      error:
          '正在查找手柄…（系统当前有 ${scan.scannedCount} 个输入设备，'
          '没有带线性扳机轴的手柄；请确认手柄已连接并已唤醒）',
    );
  }

  Future<void> _readDevice(EvdevDevice device, int axisCode) async {
    final path = '$devInputDirectory/${device.eventHandler}';
    final results = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();
    final closed = Completer<void>();
    Object? workerError;
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
        case 'jsAxisError':
          if (_running) {
            _emitter.emit(
              GamepadSnapshot(
                status: GamepadInputStatus.error,
                deviceName: device.name,
                error:
                    '无法通过旧版 joystick 接口（${map['path']}）定位扳机轴：'
                    '请给 /dev/input/event* 加上读取权限后重试。',
              ),
            );
          }
        case 'stopped':
          if (!closed.isCompleted) closed.complete();
      }
    });

    // 工作 isolate 崩溃时不会走 worker 的 finally 分支，也就不会发
    // 'stopped'；用 onError/onExit 兜底，避免主循环永远卡在“正在查找”。
    errors.listen((message) {
      if (message is List && message.isNotEmpty) workerError ??= message.first;
      if (!closed.isCompleted) closed.complete();
    });

    try {
      final isolate = await Isolate.spawn(
        _readTriggerIsolate,
        <Object?>[
          results.sendPort,
          path,
          axisCode,
          // evdev 节点打不开时（默认 0660 root:input）退回旧版 joystick 节点：
          // /dev/input/js* 是 0664，任何用户都能读。
          device.joystickHandler == null
              ? null
              : '$devInputDirectory/${device.joystickHandler}',
          jsAxisIndexFromBits(device.absBits, axisCode),
        ],
        onError: errors.sendPort,
        onExit: exit.sendPort,
      );
      _worker = isolate;
      if (!_running) _workerCommands?.send('stop');
      // 健康会话会一直读到设备断开（worker 发 'stopped'）或 isolate 退出。
      // 这里不能再用固定超时兜底：之前 5 秒的超时会把正常工作的会话每 5 秒
      // 杀掉一次、重发 rawValue 为 null 的 ready，踏板会周期性失效（还会漏
      // 关 fd）；设备真的拔掉时 worker 的 poll 会拿到 POLLHUP/POLLERR。
      await Future.any<Object?>(<Future<Object?>>[
        closed.future,
        exit.first,
      ]);
      if (!closed.isCompleted) {
        // 让 isolate 退出前发出的最后几条消息（例如 disconnected）先送达。
        await closed.future.timeout(
          const Duration(milliseconds: 200),
          onTimeout: () {},
        );
      }
      final error = workerError;
      if (error != null && _running) {
        _emitter.emit(
          GamepadSnapshot(
            status: GamepadInputStatus.error,
            error: '读取手柄时出错：$error',
          ),
        );
      }
    } finally {
      await subscription.cancel();
      errors.close();
      exit.close();
      results.close();
      _workerCommands = null;
      final worker = _worker;
      _worker = null;
      worker?.kill(priority: Isolate.beforeNextEvent);
    }
  }

  String _describeOpenError(int errorCode, String path) {
    if (errorCode == 13) {
      return '没有权限读取 $path：/dev/input/event* 默认属于 root:input 组，'
          '而且这只手柄也没有可读的 /dev/input/js* 节点可以替代。'
          '请用管理员权限执行：'
          'echo \'KERNEL=="event*", SUBSYSTEM=="input", MODE="0660", GROUP="input", '
          'TAG+="uaccess"\' | sudo tee /etc/udev/rules.d/99-gamepad.rules && '
          'sudo udevadm control --reload-rules && sudo udevadm trigger'
          '（不必重新登录；网页版在 Linux 上也需要同样的权限）。';
    }
    if (errorCode == 2) return '手柄输入设备 $path 已移除，正在重新查找…';
    return '无法打开手柄输入设备 $path（errno $errorCode）。';
  }

  Future<_DeviceScan> _findDevice() async {
    final List<EvdevDevice> devices;
    try {
      final text = await File(procDevicesPath).readAsString();
      devices = parseProcInputDevices(text);
    } on FileSystemException catch (error) {
      return _DeviceScan(
        error:
            '无法读取 $procDevicesPath：${error.message}。'
            '容器、虚拟机或受限沙箱里可能读不到输入设备列表。',
      );
    }
    for (final device in devices) {
      if (resolveTriggerAxis(device.absBits, _trigger) != null) {
        return _DeviceScan(device: device, scannedCount: devices.length);
      }
    }
    // 没有带扳机轴的设备，但内核把某些设备注册成了 joystick：这多半是
    // Switch Pro 这类“数字按键式扳机”手柄，要点名告诉用户。
    final joystickNames = <String>[
      for (final device in devices)
        if (looksLikeGamepad(device) && !supportsAnalogTrigger(device.absBits))
          device.name,
    ];
    return _DeviceScan(
      scannedCount: devices.length,
      joystickNames: joystickNames,
    );
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

/// 一次设备扫描的结果。
class _DeviceScan {
  const _DeviceScan({
    this.device,
    this.scannedCount = 0,
    this.joystickNames = const <String>[],
    this.error,
  });

  /// 带线性扳机轴的设备；没有则为 null。
  final EvdevDevice? device;

  /// 扫描到的输入设备数量。
  final int scannedCount;

  /// 被内核识别成 joystick、但没有线性扳机轴的设备名。
  final List<String> joystickNames;

  /// 扫描本身失败时的说明（例如读不到 `/proc`）。
  final String? error;
}

/// 在独立 isolate 中等待并读取设备事件，把结果发回主 isolate。
///
/// 优先用 evdev（`/dev/input/event*`，能拿到精确量程）；如果它因为权限问题
/// 打不开，就退回旧版 joystick 接口（`/dev/input/js*` 默认 0664，任何用户
/// 都能读，代价是内核会把轴值缩放到 -32767..32767）。
Future<void> _readTriggerIsolate(List<Object?> args) async {
  final results = args[0] as SendPort;
  final path = args[1] as String;
  final axisCode = args[2] as int;
  final jsPath = args[3] as String?;
  final jsAxisFallback = args[4] as int?;

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

  var opened = io.open(path);
  var usingJoystick = false;
  if (!opened.isOpen && jsPath != null && _isPermissionError(opened.errorCode)) {
    final fallback = io.open(jsPath);
    if (fallback.isOpen) {
      opened = fallback;
      usingJoystick = true;
    }
  }
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
  var jsAxis = -1;
  if (usingJoystick) {
    final axisMap = io.jsAxisMap(fd);
    final resolved =
        (axisMap == null ? null : jsAxisIndexFor(axisMap, axisCode)) ??
        jsAxisFallback;
    if (resolved == null) {
      io.close(fd);
      io.dispose();
      commands.close();
      results.send(<String, Object?>{'type': 'jsAxisError', 'path': jsPath});
      results.send(<String, Object?>{'type': 'stopped'});
      return;
    }
    jsAxis = resolved;
    results.send(<String, Object?>{
      'type': 'ready',
      'min': jsTriggerRawMinimum,
      'max': jsTriggerRawMaximum,
      'channel': 'joystick',
    });
  } else {
    final range = io.absRange(fd, axisCode);
    results.send(<String, Object?>{
      'type': 'ready',
      'min': range?.minimum,
      'max': range?.maximum,
      'channel': 'evdev',
    });
  }

  final jsBuffer = JsEventBuffer();
  final evdevBuffer = EvdevEventBuffer();
  final maxBytes = (usingJoystick ? jsEventSize : evdevEventSize) * 64;
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
      final chunk = io.read(fd, maxBytes);
      if (stop) break;
      // null 表示读失败或读到 EOF（设备已被移除）；空列表只是“暂时没有
      // 数据”（非阻塞 fd 的 EAGAIN 或被信号打断），继续轮询即可。
      if (chunk == null) {
        results.send(<String, Object?>{'type': 'disconnected'});
        break;
      }
      if (chunk.isEmpty) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      if (usingJoystick) {
        for (final event in jsBuffer.add(chunk)) {
          if (!event.isAxis || event.number != jsAxis) continue;
          results.send(<String, Object?>{
            'type': 'value',
            'raw': jsTriggerRaw(event.value),
          });
        }
      } else {
        for (final event in evdevBuffer.add(chunk)) {
          if (event.type != evAbs || event.code != axisCode) continue;
          results.send(<String, Object?>{'type': 'value', 'raw': event.value});
        }
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

/// 打不开设备节点时，EACCES / EPERM 属于权限问题，值得退回 js 节点再试。
bool _isPermissionError(int errorCode) => errorCode == 13 || errorCode == 1;
