import 'dart:async';

import 'package:flutter/foundation.dart';

import 'gamepad_trigger.dart';
import 'gamepad_trigger_source.dart';

/// 把手柄扳机的原始读数归一化为 0–1 的踏板位置。
///
/// 只负责输入：启用/停用、左右扳机、反向、量程校准和数值归一化；
/// 如何写入效果器（例如哇音位置）由页面决定。
class ExpressionPedalController extends ChangeNotifier {
  ExpressionPedalController({
    GamepadTriggerSource? source,
    PedalTrigger initialTrigger = PedalTrigger.right,
  }) : _source = source ?? createGamepadTriggerSource(),
       _trigger = initialTrigger;

  final GamepadTriggerSource _source;

  StreamSubscription<GamepadSnapshot>? _subscription;
  PedalTrigger _trigger;
  bool _enabled = false;
  bool _invert = false;
  int? _minRaw;
  int? _maxRaw;
  double _value = 0;
  GamepadSnapshot _snapshot = const GamepadSnapshot.searching();

  /// 当前平台是否支持读取手柄扳机。
  bool get supported => _source.supported;

  /// 平台限制说明；没有附加限制时为 null。
  String? get platformNote => _source.platformNote;

  /// 是否已启用手柄踏板输入。
  bool get enabled => _enabled;

  /// 当前监听的扳机。
  PedalTrigger get trigger => _trigger;

  /// 最近一次读取快照。
  GamepadSnapshot get snapshot => _snapshot;

  GamepadInputStatus get status => _snapshot.status;

  /// 面向用户的读取错误说明。
  String? get error => _snapshot.error;

  /// 已连接的手柄名称；未连接时为空字符串。
  String get deviceName => _snapshot.deviceName ?? '';

  /// 当前扳机原始读数；尚未读到时为 null。
  int? get rawValue => _snapshot.rawValue;

  /// 归一化后的踏板位置（0–1）。
  double get value => _value;

  /// 是否踩过反向。
  bool get invert => _invert;

  /// 是否已手动校准上下限。
  bool get calibrated => _minRaw != null && _maxRaw != null;

  /// 归一化使用的最低原始值。
  int get minRaw => _minRaw ?? _snapshot.rawMin ?? 0;

  /// 归一化使用的最高原始值。
  int get maxRaw => _maxRaw ?? _snapshot.rawMax ?? 255;

  /// 启用或停用手柄踏板输入。
  Future<void> setEnabled(bool enabled) async {
    if (!supported || enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) {
      _subscription ??= _source.snapshots.listen(
        _handleSnapshot,
        onError: _handleStreamError,
      );
      await _source.start(_trigger);
    } else {
      await _source.stop();
      await _subscription?.cancel();
      _subscription = null;
      _snapshot = const GamepadSnapshot.searching();
    }
    notifyListeners();
  }

  /// 切换监听的左右扳机；已启用时会重启读取。
  Future<void> setTrigger(PedalTrigger trigger) async {
    if (trigger == _trigger) return;
    _trigger = trigger;
    if (_enabled) {
      await _source.stop();
      _snapshot = const GamepadSnapshot.searching();
      _value = 0;
      await _source.start(_trigger);
    }
    notifyListeners();
  }

  /// 切换“踩下 = 位置变小”。
  void setInvert(bool invert) {
    if (invert == _invert) return;
    _invert = invert;
    final raw = _snapshot.rawValue;
    if (raw != null) _value = _normalize(raw);
    notifyListeners();
  }

  /// 把当前读数记为扳机最低点；没有读数时返回 false。
  bool captureMin() {
    final raw = _snapshot.rawValue;
    if (raw == null) return false;
    _minRaw = raw;
    if (_maxRaw != null && _maxRaw! <= raw) _maxRaw = null;
    _value = _normalize(raw);
    notifyListeners();
    return true;
  }

  /// 把当前读数记为扳机最高点；没有读数时返回 false。
  bool captureMax() {
    final raw = _snapshot.rawValue;
    if (raw == null) return false;
    _maxRaw = raw;
    if (_minRaw != null && _minRaw! >= raw) _minRaw = null;
    _value = _normalize(raw);
    notifyListeners();
    return true;
  }

  /// 清除手动校准，回到平台量程或常见量程。
  void resetCalibration() {
    _minRaw = null;
    _maxRaw = null;
    final raw = _snapshot.rawValue;
    if (raw != null) _value = _normalize(raw);
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_source.dispose());
    super.dispose();
  }

  void _handleSnapshot(GamepadSnapshot snapshot) {
    _snapshot = snapshot;
    final raw = snapshot.rawValue;
    if (raw != null) _value = _normalize(raw);
    notifyListeners();
  }

  void _handleStreamError(Object error) {
    _snapshot = GamepadSnapshot(
      status: GamepadInputStatus.error,
      error: '$error',
    );
    notifyListeners();
  }

  double _normalize(int raw) {
    final min = minRaw;
    final max = maxRaw;
    final span = max - min;
    var value = span > 0 ? (raw - min) / span : (raw >= max ? 1.0 : 0.0);
    if (_invert) value = 1 - value;
    return value.clamp(0.0, 1.0).toDouble();
  }
}
