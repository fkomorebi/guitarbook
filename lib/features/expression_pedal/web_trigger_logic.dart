import 'gamepad_trigger.dart';

/// 标准手柄映射（standard gamepad mapping）里左扳机（L2）的按钮下标。
const int kLeftTriggerButtonIndex = 6;

/// 标准手柄映射里右扳机（R2）的按钮下标。
const int kRightTriggerButtonIndex = 7;

/// Web 端扳机读数的最小值；与 Windows XInput 版保持同一量程。
const int kWebTriggerRawMin = 0;

/// Web 端扳机读数的最大值；与 Windows XInput 版保持同一量程。
const int kWebTriggerRawMax = 255;

/// 某个扳机在标准映射里的按钮下标。
int triggerButtonIndex(PedalTrigger trigger) =>
    trigger == PedalTrigger.left
    ? kLeftTriggerButtonIndex
    : kRightTriggerButtonIndex;

/// 从浏览器的按钮模拟量列表里取出指定扳机的模拟量（0.0–1.0）。
///
/// 浏览器返回的按钮数量不足时（没有标准映射的扳机按钮）返回 null。
double? analogValueFor({
  required List<double> buttonValues,
  required PedalTrigger trigger,
}) {
  final index = triggerButtonIndex(trigger);
  if (index < 0 || index >= buttonValues.length) return null;
  final value = buttonValues[index];
  if (value.isNaN) return null;
  return value.clamp(0.0, 1.0).toDouble();
}

/// 把 0.0–1.0 的扳机模拟量换算成 0–255 的整数原始值。
///
/// 与 Windows XInput 版使用同一量程，方便两端的校准值与曲线一致。
/// 按钮缺失时返回 null。
int? triggerRawFromButtons({
  required List<double> buttonValues,
  required PedalTrigger trigger,
}) {
  final value = analogValueFor(
    buttonValues: buttonValues,
    trigger: trigger,
  );
  if (value == null) return null;
  final raw = (value * kWebTriggerRawMax).round();
  return raw.clamp(kWebTriggerRawMin, kWebTriggerRawMax);
}

/// 把浏览器给出的手柄 id 整理成简短好读的名字。
///
/// 常见格式：
/// - Chrome/Edge：`Xbox 360 Controller (XInput STANDARD GAMEPAD)`、
///   `Flydigi Apex 5 (Vendor: 0e6f Product: 0205)`；
/// - Firefox：`<vendor>-<product>-<名字>`，例如 `810-3-USB Gamepad`。
String gamepadDisplayName(String id) {
  var text = id.trim();
  if (text.isEmpty) return '未知手柄';

  // 去掉厂商附带的括号说明。
  final paren = text.indexOf('(');
  if (paren >= 0) text = text.substring(0, paren).trim();

  // 去掉 Firefox 的 vendor-product- 前缀（十六进制，长度不定）。
  final vendorPrefix = RegExp(r'^[0-9a-fA-F]{3,4}-[0-9a-fA-F]{1,4}-');
  final match = vendorPrefix.firstMatch(text);
  if (match != null) text = text.substring(match.end).trim();

  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '未知手柄';
  if (text.length > 40) text = '${text.substring(0, 40)}…';
  return text;
}

/// 网页端读取状态机：记住手柄是否曾经连上。
///
/// 手柄断开后，下一次轮询就会找不到设备；如果此时直接上报通用的
/// 「正在查找手柄…」，刚才的「手柄已断开」提示会立刻被覆盖，用户看不出
/// 手柄曾经在线过。这里记住断开状态，直到重新连上才清除。
class WebGamepadPresence {
  String? _deviceId;
  bool _disconnected = false;

  /// 浏览器通知断开的那台手柄。
  ///
  /// 浏览器在设备断开后可能还在列表里留一条记录，重新连上（浏览器再发一次
  /// 连接事件）之前不再使用它，免得刚报完「已断开」又被同一条残留记录顶回
  /// 「已连接」。
  String? _ignoredId;

  /// 当前连着的设备 id；断开后为空。
  String? get deviceId => _deviceId;

  /// 是否处于「曾经连上、现在断开」的状态。
  bool get disconnected => _disconnected;

  /// 浏览器刚通知断开、列表里可能还有残留记录的设备 id。
  String? get ignoredId => _ignoredId;

  /// 这个设备是不是浏览器刚通知断开的那台（列表里的残留记录）。
  bool isIgnored(String id) => _ignoredId != null && _ignoredId == id;

  /// 记录一次轮询结果；返回 true 表示连接状态发生了变化。
  bool update({required bool found, required String id}) {
    if (!found) {
      if (_deviceId == null) return false;
      _deviceId = null;
      _disconnected = true;
      return true;
    }
    final changed = _deviceId != id;
    _deviceId = id;
    _disconnected = false;
    return changed;
  }

  /// 处理浏览器上报的连接/断开事件。
  ///
  /// 返回 true 表示连接状态发生了变化。断开的事件会立刻把状态记成
  /// 「已断开」，这样不用等下一次轮询就能告诉用户手柄掉了。
  bool handleEvent({required WebGamepadEvent event, required String id}) {
    switch (event) {
      case WebGamepadEvent.connected:
        // 浏览器说它又连上了：列表里的残留记录可以重新用。
        if (id.isNotEmpty && _ignoredId == id) _ignoredId = null;
        // 连接事件只说明浏览器刚把设备交出来，具体读数由随后的扫描确认。
        return false;
      case WebGamepadEvent.disconnected:
        if (id.isEmpty) return false;
        _ignoredId = id;
        if (_deviceId == null) return false;
        // 断开的不是正在用的那台手柄时，当前状态不变。
        if (_deviceId != id) return false;
        _deviceId = null;
        _disconnected = true;
        return true;
    }
  }

  /// 重置状态（启用或停用读取时）。
  void reset() {
    _deviceId = null;
    _disconnected = false;
    _ignoredId = null;
  }
}

/// 浏览器上报的手柄连接状态变化。
enum WebGamepadEvent {
  /// 浏览器刚把手柄交给网页。
  connected,

  /// 浏览器刚把手柄收回去。
  disconnected,
}

/// 收到连接事件后要执行的动作。
enum WebGamepadEventAction {
  /// 立刻重新扫描一次手柄列表。
  rescan,

  /// 立刻重新扫描一次，并马上上报「手柄已断开」。
  rescanAndReportDisconnect,
}

/// 根据浏览器事件和当前已知的设备，决定收到事件后要做什么。
///
/// 断开的不是正在用的那台手柄时（例如同时插着两只），只需要重新扫描，
/// 剩下的手柄会被正常接管。
WebGamepadEventAction webGamepadEventAction({
  required WebGamepadEvent event,
  required String? eventDeviceId,
  required String? knownDeviceId,
}) {
  switch (event) {
    case WebGamepadEvent.connected:
      return WebGamepadEventAction.rescan;
    case WebGamepadEvent.disconnected:
      if (knownDeviceId == null) return WebGamepadEventAction.rescan;
      if (eventDeviceId == null || eventDeviceId == knownDeviceId) {
        return WebGamepadEventAction.rescanAndReportDisconnect;
      }
      return WebGamepadEventAction.rescan;
  }
}

/// 浏览器暂时看不到手柄时的排查提示。
///
/// 覆盖三种最常见的原因：
/// 1. 浏览器还没把手柄交给网页——多数浏览器要按一次手柄按键才会交出设备；
/// 2. Linux 上浏览器读不到 /dev/input/event*——当前用户不在 input 组，
///    或者缺少给 event* 设备放权的 udev 规则（Chrome 的官方规则没装时
///    浏览器同样看不到手柄）；
/// 3. 网页不在前台——浏览器会在页面切到后台时暂停手柄读取。
const String kWebGamepadSearchHint =
    '浏览器还没有把手柄交给网页：请先按一下手柄上的任意按键。\n'
    '按了仍然找不到时，Linux 上浏览器还要能读取 /dev/input/event*：'
    '请把当前用户加入 input 组，或安装 udev 规则给 event* 设备加上 uaccess 权限；'
    'Chrome 的官方规则缺失时，浏览器同样看不到手柄。\n'
    '另外请保持网页在前台，切到后台时浏览器会暂停手柄读取。';

/// 手柄接上了、但没有线性扳机时的说明。
String noAnalogTriggerMessage(String deviceName) =>
    '手柄“$deviceName”没有可用的线性扳机'
    '（浏览器的标准手柄映射要求左右扳机按钮提供模拟量）。';

/// 查找状态的快照。
///
/// 断开后一直保留具体的断开说明，不会退回成笼统的「正在查找手柄…」；
/// 从没连上过时给出可以直接照着做的排查步骤。
GamepadSnapshot searchingSnapshot({required bool disconnected}) =>
    disconnected
        ? const GamepadSnapshot(
            status: GamepadInputStatus.searching,
            error: '手柄已断开，正在重新查找…',
          )
        : const GamepadSnapshot(
            status: GamepadInputStatus.searching,
            error: kWebGamepadSearchHint,
          );
