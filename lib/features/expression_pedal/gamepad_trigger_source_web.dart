import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'gamepad_trigger.dart';
import 'web_trigger_logic.dart';

/// 网页端轮询 Gamepad API 的间隔（毫秒）。
///
/// 浏览器没有提供手柄读数的推送接口，只能轮询 `navigator.getGamepads()`；
/// 24 毫秒约合 42Hz，足够驱动哇音踏板，又不会给 JS 引擎造成明显负担。
const int kWebGamepadPollIntervalMs = 24;

/// 通过浏览器 Gamepad API 读取手柄线性扳机。
///
/// 读取标准手柄映射（standard gamepad mapping）里 button index 6（L2）与
/// index 7（R2）的模拟量，浏览器把扳机归一化到 0.0–1.0，这里再换算成
/// 0–255 的整数原始值，与 Windows XInput 版保持同一量程。
///
/// 浏览器侧的限制：
/// - 浏览器通常要等用户按一次手柄按键，才会把手柄交给网页；
/// - 页面切到后台时浏览器会节流定时器，读取会暂停；
/// - Linux 上浏览器还要能读 /dev/input/event*，否则根本看不到手柄；
/// - 只对标准映射的手柄有效，映射不完整时扳机会退化成数字按键。
///
/// 手柄连上或断开时浏览器会通知页面，这时立刻刷新一次状态，
/// 用户不用等下一个轮询周期。
class WebGamepadTriggerSource implements GamepadTriggerSource {
  final StreamController<GamepadSnapshot> _snapshots =
      StreamController<GamepadSnapshot>.broadcast();
  late final GamepadSnapshotEmitter _emitter = GamepadSnapshotEmitter(
    _snapshots,
  );

  Timer? _timer;
  PedalTrigger _trigger = PedalTrigger.right;
  bool _running = false;
  bool _disposed = false;

  /// 记录手柄是否曾经连上，避免断开提示被通用提示覆盖。
  final WebGamepadPresence _presence = WebGamepadPresence();

  /// 上一次读到的原始值；null 表示尚未读到。
  int? _lastRaw;

  /// 浏览器连接事件监听器；为空表示还没注册。
  JSFunction? _gamepadConnectedHandler;
  JSFunction? _gamepadDisconnectedHandler;

  @override
  bool get supported => true;

  @override
  String? get platformNote =>
      '网页版通过浏览器 Gamepad API 读取手柄；'
      '浏览器通常要按一次手柄按键才会把手柄交给网页，'
      '页面切到后台时浏览器会暂停读取。';

  @override
  Stream<GamepadSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start(PedalTrigger trigger) async {
    if (_disposed) return;
    _trigger = trigger;
    if (_running) {
      // 已在监听：只切换扳机，并作废旧读数以便重新上报。
      _presence.reset();
      _lastRaw = null;
      return;
    }
    _running = true;
    _listenForGamepadEvents();
    _poll();
    _timer = Timer.periodic(
      const Duration(milliseconds: kWebGamepadPollIntervalMs),
      (_) => _poll(),
    );
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _presence.reset();
    _lastRaw = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    _removeGamepadEventListeners();
    await _snapshots.close();
  }

  /// 监听浏览器的连接/断开事件。
  ///
  /// 浏览器在手柄连上或断开时会通知页面，这时立刻刷新一次状态，
  /// 用户不用等下一个轮询周期。
  void _listenForGamepadEvents() {
    if (_gamepadConnectedHandler != null) return;
    final connected = ((web.GamepadEvent event) {
      _handleGamepadEvent(WebGamepadEvent.connected, event.gamepad);
    }).toJS;
    final disconnected = ((web.GamepadEvent event) {
      _handleGamepadEvent(WebGamepadEvent.disconnected, event.gamepad);
    }).toJS;
    web.window.addEventListener('gamepadconnected', connected);
    web.window.addEventListener('gamepaddisconnected', disconnected);
    _gamepadConnectedHandler = connected;
    _gamepadDisconnectedHandler = disconnected;
  }

  /// 注销浏览器的连接/断开事件。
  void _removeGamepadEventListeners() {
    final connected = _gamepadConnectedHandler;
    if (connected != null) {
      web.window.removeEventListener('gamepadconnected', connected);
      _gamepadConnectedHandler = null;
    }
    final disconnected = _gamepadDisconnectedHandler;
    if (disconnected != null) {
      web.window.removeEventListener('gamepaddisconnected', disconnected);
      _gamepadDisconnectedHandler = null;
    }
  }

  /// 浏览器报告手柄连上或断开时立刻刷新状态。
  void _handleGamepadEvent(WebGamepadEvent event, web.Gamepad gamepad) {
    if (!_running || _disposed) return;
    final action = webGamepadEventAction(
      event: event,
      eventDeviceId: gamepad.id,
      knownDeviceId: _presence.deviceId,
    );
    // 先把事件记进状态机：连接事件会解除「刚断开」的忽略标记，
    // 断开事件会立刻把状态记成「已断开」。
    _presence.handleEvent(event: event, id: gamepad.id);
    if (action == WebGamepadEventAction.rescanAndReportDisconnect) {
      // 浏览器通知手柄断开：立刻告诉用户，不用等下一个轮询周期。
      _lastRaw = null;
      _emitter.emit(searchingSnapshot(disconnected: true));
    }
    // 连上时同样立刻扫描一次，让用户不用等下一个轮询周期。
    _poll();
  }

  void _poll() {
    if (!_running || _disposed) return;
    try {
      _pollOnce();
    } on Object catch (error) {
      // Gamepad API 不可用或读取异常：停掉轮询并报告错误，避免反复抛异常。
      _running = false;
      _timer?.cancel();
      _timer = null;
      _emitter.emit(
        GamepadSnapshot(
          status: GamepadInputStatus.error,
          error: '读取手柄失败：$error',
        ),
      );
    }
  }

  void _pollOnce() {
    final gamepad = _findGamepad();
    final found = gamepad != null;
    final changed = _presence.update(
      found: found,
      id: found ? gamepad.id : '',
    );
    if (!found) {
      _lastRaw = null;
      // 断开后一直保留具体的断开说明，不会被通用的「正在查找手柄…」覆盖。
      _emitter.emit(searchingSnapshot(disconnected: _presence.disconnected));
      return;
    }

    final id = gamepad.id;
    final name = gamepadDisplayName(id);

    final buttonValues = <double>[];
    for (final button in gamepad.buttons.toDart) {
      buttonValues.add(button.value);
    }
    final raw = triggerRawFromButtons(
      buttonValues: buttonValues,
      trigger: _trigger,
    );

    if (raw == null) {
      // 标准映射里没有左右扳机按钮：这只手柄没有线性扳机。
      _lastRaw = null;
      _emitter.emit(
        GamepadSnapshot(
          status: GamepadInputStatus.error,
          deviceName: name,
          error: noAnalogTriggerMessage(name),
        ),
      );
      return;
    }

    if (!changed && _lastRaw == raw) return;
    _lastRaw = raw;
    _emitter.emit(
      GamepadSnapshot(
        status: GamepadInputStatus.ready,
        deviceName: name,
        rawValue: raw,
        rawMin: kWebTriggerRawMin,
        rawMax: kWebTriggerRawMax,
      ),
    );
  }

  /// 找到第一个已连接的手柄。
  web.Gamepad? _findGamepad() {
    final pads = web.window.navigator.getGamepads().toDart;
    for (final pad in pads) {
      if (pad == null) continue;
      if (!pad.connected) continue;
      // 浏览器刚通知断开的手柄，列表里可能还留着一条记录，先不用它，
      // 免得刚报完「已断开」又被这条残留记录顶回「已连接」。
      if (_presence.isIgnored(pad.id)) continue;
      return pad;
    }
    return null;
  }
}

/// 网页版的手柄扳机读取源。
GamepadTriggerSource createGamepadTriggerSource() => WebGamepadTriggerSource();
