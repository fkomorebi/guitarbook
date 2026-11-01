import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'gamepad_trigger.dart';

typedef _XInputGetStateNative =
    Int32 Function(Uint32 userIndex, Pointer<Uint8> state);
typedef _XInputGetStateDart = int Function(int userIndex, Pointer<Uint8> state);

const int _errorSuccess = 0;

/// Windows 8+ 自带 xinput1_4；旧系统上回退到 DXSDK / Vista 的运行库。
const List<String> _libraryNames = [
  'xinput1_4.dll',
  'xinput1_3.dll',
  'xinput9_1_0.dll',
];

/// `XINPUT_STATE` 的字节数：
/// 4 字节包序号 + `XINPUT_GAMEPAD`（wButtons 2 + 左右扳机各 1 + 四个摇杆轴 8）。
const int _stateSize = 16;
const int _leftTriggerOffset = 6;
const int _rightTriggerOffset = 7;
const int _triggerMax = 255;
const int _pollIntervalMs = 16;

/// 通过 Windows XInput 读取 Xbox 兼容手柄的线性扳机。
///
/// XInput 只能看到 XInput 兼容手柄（Xbox 系列）；PlayStation 手柄需要先经
/// Steam Input、DS4Windows 等映射。
class WindowsGamepadTriggerSource implements GamepadTriggerSource {
  final StreamController<GamepadSnapshot> _snapshots =
      StreamController<GamepadSnapshot>.broadcast();
  late final GamepadSnapshotEmitter _emitter = GamepadSnapshotEmitter(
    _snapshots,
  );

  _XInputGetStateDart? _getState;
  Pointer<Uint8>? _stateBuffer;
  Timer? _timer;
  PedalTrigger _trigger = PedalTrigger.right;
  bool _running = false;
  int? _slot;
  int? _lastRaw;

  @override
  bool get supported => true;

  @override
  String? get platformNote =>
      '仅支持 XInput 兼容手柄（Xbox 系列）。PlayStation 手柄需先经 Steam Input 或 DS4Windows 映射后才能读取。';

  @override
  Stream<GamepadSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start(PedalTrigger trigger) async {
    if (_running) return;
    _trigger = trigger;
    _running = true;
    try {
      _getState ??= _loadGetState();
      _stateBuffer ??= calloc<Uint8>(_stateSize);
    } on Object catch (error) {
      _running = false;
      _emitter.emit(
        GamepadSnapshot(status: GamepadInputStatus.error, error: '$error'),
      );
      return;
    }
    _poll();
    _timer = Timer.periodic(
      const Duration(milliseconds: _pollIntervalMs),
      (_) => _poll(),
    );
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _slot = null;
    _lastRaw = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    final buffer = _stateBuffer;
    _stateBuffer = null;
    if (buffer != null) calloc.free(buffer);
    await _snapshots.close();
  }

  void _poll() {
    final getState = _getState;
    final buffer = _stateBuffer;
    if (!_running || getState == null || buffer == null) return;
    for (var slot = 0; slot < 4; slot++) {
      if (getState(slot, buffer) != _errorSuccess) continue;
      final offset = _trigger == PedalTrigger.left
          ? _leftTriggerOffset
          : _rightTriggerOffset;
      final raw = buffer[offset];
      if (slot == _slot && raw == _lastRaw) return;
      _slot = slot;
      _lastRaw = raw;
      _emitter.emit(
        GamepadSnapshot(
          status: GamepadInputStatus.ready,
          deviceName: 'XInput 手柄 ${slot + 1}',
          rawValue: raw,
          rawMin: 0,
          rawMax: _triggerMax,
        ),
      );
      return;
    }
    if (_slot != null) {
      _slot = null;
      _lastRaw = null;
      _emitter.emit(const GamepadSnapshot.searching());
    }
  }

  static _XInputGetStateDart _loadGetState() {
    Object? lastError;
    for (final name in _libraryNames) {
      try {
        final library = DynamicLibrary.open(name);
        return library
            .lookupFunction<_XInputGetStateNative, _XInputGetStateDart>(
              'XInputGetState',
            );
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw UnsupportedError(
      '未找到 XInput 运行库（xinput1_4.dll / xinput1_3.dll / xinput9_1_0.dll）：'
      '$lastError',
    );
  }
}
