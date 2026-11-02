import 'dart:async';

/// 手柄上的两路线性扳机。
enum PedalTrigger {
  left('左扳机'),
  right('右扳机');

  const PedalTrigger(this.label);

  final String label;
}

/// 手柄输入层的状态。
enum GamepadInputStatus {
  /// 当前平台不支持读取手柄。
  unsupported,

  /// 已启用但还没有找到可用手柄。
  searching,

  /// 已连接手柄，可以读取扳机原始值。
  ready,

  /// 读取失败（无权限、设备被占用等）。
  error,
}

/// 一次手柄读取快照。
class GamepadSnapshot {
  const GamepadSnapshot({
    required this.status,
    this.deviceName,
    this.rawValue,
    this.rawMin,
    this.rawMax,
    this.error,
  });

  const GamepadSnapshot.searching()
    : status = GamepadInputStatus.searching,
      deviceName = null,
      rawValue = null,
      rawMin = null,
      rawMax = null,
      error = null;

  const GamepadSnapshot.unsupported(String message)
    : status = GamepadInputStatus.unsupported,
      deviceName = null,
      rawValue = null,
      rawMin = null,
      rawMax = null,
      error = message;

  final GamepadInputStatus status;

  /// 手柄名称；[GamepadInputStatus.ready] 时由平台填入。
  final String? deviceName;

  /// 扳机原始读数；尚未读到时为 null。
  final int? rawValue;

  /// 平台报告的扳机量程；未知时为 null（改为使用校准值或常见量程）。
  final int? rawMin;
  final int? rawMax;

  /// 面向用户的错误说明。
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is GamepadSnapshot &&
      other.status == status &&
      other.deviceName == deviceName &&
      other.rawValue == rawValue &&
      other.rawMin == rawMin &&
      other.rawMax == rawMax &&
      other.error == error;

  @override
  int get hashCode =>
      Object.hash(status, deviceName, rawValue, rawMin, rawMax, error);
}

/// 手柄扳机读取源的平台抽象。
abstract class GamepadTriggerSource {
  /// 当前平台是否支持读取手柄线性扳机。
  bool get supported;

  /// 平台限制说明（展示给用户）；没有附加限制时为 null。
  String? get platformNote;

  /// 设备状态与扳机原始值快照。
  Stream<GamepadSnapshot> get snapshots;

  /// 开始监听 [trigger]（幂等）。
  Future<void> start(PedalTrigger trigger);

  /// 停止监听并释放设备（幂等）。
  Future<void> stop();

  /// 释放资源。
  Future<void> dispose();
}

/// 不支持手柄输入的平台实现。
class UnsupportedGamepadTriggerSource implements GamepadTriggerSource {
  UnsupportedGamepadTriggerSource([this.platformNote]);

  @override
  final String? platformNote;

  @override
  bool get supported => false;

  @override
  Stream<GamepadSnapshot> get snapshots =>
      const Stream<GamepadSnapshot>.empty();

  @override
  Future<void> start(PedalTrigger trigger) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// 对快照去重后写入流，避免轮询时重复通知界面。
class GamepadSnapshotEmitter {
  GamepadSnapshotEmitter(this._controller);

  final StreamController<GamepadSnapshot> _controller;
  GamepadSnapshot? _last;

  void emit(GamepadSnapshot snapshot) {
    if (snapshot == _last) return;
    _last = snapshot;
    if (!_controller.isClosed) _controller.add(snapshot);
  }

  /// 清空去重记录，让下一次 [emit] 的快照一定被发出。
  ///
  /// 每次开始新的读取会话前都要调用：停用/切换扳机后重新启用的第一条
  /// `ready` 快照（`rawValue` 仍为 null）往往与上一次会话完全相同，如果
  /// 保留 [_last] 就会把它当成重复而丢弃，界面会一直停在“正在查找手柄…”。
  void reset() {
    _last = null;
  }
}
