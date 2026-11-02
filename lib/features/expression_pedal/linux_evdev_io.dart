import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linux_abs_info.dart';
import 'linux_joystick.dart';

/// `poll(2)` 的事件位。
const int pollIn = 0x001;
const int pollErr = 0x008;
const int pollHup = 0x010;
const int pollNval = 0x020;

/// Linux 的 `O_NONBLOCK`（x86_64 / aarch64 / arm 通用）。
const int _oNonBlock = 0x800;

/// `EAGAIN` / `EINTR`：内核暂时没有数据。
const int _eagain = 11;
const int _eintr = 4;

/// `struct pollfd { int fd; short events; short revents; }`。
final class _PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

/// 打开 evdev 节点的结果；失败时 [errorCode] 是 errno。
class EvdevOpenResult {
  const EvdevOpenResult(this.fd, this.errorCode);

  final int fd;
  final int errorCode;

  bool get isOpen => fd >= 0;
}

/// 读取 evdev 设备所需的系统调用封装。
///
/// `dart:io` 不暴露文件描述符，无法做 `poll` 与 ioctl；而且设备的阻塞 read
/// 在停用控制时无法被可靠打断，所以这里用非阻塞 fd + 100 毫秒轮询。
class LinuxEvdevIo {
  LinuxEvdevIo({this.bufferSize = 4096});

  /// 单次读取的最大字节数。
  final int bufferSize;

  bool _loaded = false;
  int Function(Pointer<Utf8>, int, int)? _open;
  int Function(int)? _close;
  int Function(int, Pointer<Uint8>, int)? _read;
  int Function(Pointer<_PollFd>, int, int)? _poll;
  int Function(int, int, Pointer<Void>)? _ioctl;
  Pointer<Int32> Function()? _errnoLocation;
  Pointer<Uint8>? _readBuffer;
  Pointer<_PollFd>? _pollFd;

  void _load() {
    if (_loaded) return;
    final libc = DynamicLibrary.process();
    _open = libc
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Int32),
          int Function(Pointer<Utf8>, int, int)
        >('open');
    _close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    _read = libc
        .lookupFunction<
          IntPtr Function(Int32, Pointer<Uint8>, UintPtr),
          int Function(int, Pointer<Uint8>, int)
        >('read');
    _poll = libc
        .lookupFunction<
          Int32 Function(Pointer<_PollFd>, UintPtr, Int32),
          int Function(Pointer<_PollFd>, int, int)
        >('poll');
    _ioctl = libc
        .lookupFunction<
          Int32 Function(Int32, UintPtr, Pointer<Void>),
          int Function(int, int, Pointer<Void>)
        >('ioctl');
    _errnoLocation = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__errno_location',
        );
    _loaded = true;
  }

  int _errno() {
    try {
      return _errnoLocation!().value;
    } catch (_) {
      return 0;
    }
  }

  EvdevOpenResult open(String path) {
    _load();
    final nativePath = path.toNativeUtf8();
    try {
      // flags = O_RDONLY | O_NONBLOCK（O_RDONLY 是 0），第三个参数是
      // `mode`，只有带 O_CREAT 时才有意义，这里传 0。之前把 O_NONBLOCK 放
      // 在第三个参数、flags 传 0，fd 实际是阻塞的。
      final fd = _open!(nativePath, _oNonBlock, 0);
      return EvdevOpenResult(fd, fd < 0 ? _errno() : 0);
    } finally {
      malloc.free(nativePath);
    }
  }

  AbsAxisRange? absRange(int fd, int absCode) {
    _load();
    final info = calloc<Uint8>(inputAbsInfoSize);
    try {
      if (_ioctl!(fd, absInfoRequest(absCode), info.cast<Void>()) < 0) {
        return null;
      }
      return decodeAbsInfo(info.asTypedList(inputAbsInfoSize));
    } finally {
      calloc.free(info);
    }
  }

  /// 读取旧版 joystick 接口的轴映射表（下标是旧版轴号，值是 evdev ABS
  /// 编码）；设备不支持这个 ioctl 时返回 null。
  List<int>? jsAxisMap(int fd) {
    _load();
    final buffer = calloc<Uint8>(jsAxisMapSize);
    try {
      if (_ioctl!(fd, jsIoctlGetAxisMap, buffer.cast<Void>()) < 0) return null;
      return List<int>.generate(jsAxisMapSize, (index) => buffer[index]);
    } finally {
      calloc.free(buffer);
    }
  }

  /// 等待可读事件，最多等 [timeout]；返回 `revents`，超时返回 0，失败返回 -1。
  ///
  /// 调试构建里 Dart VM 的采样分析器默认开启（`profile_period` 约 1 毫秒），
  /// 它发的 SIGPROF 会打断阻塞中的 `poll(2)` 并返回 `EINTR`。如果不重试，读取
  /// 线程会把每次信号都当成“设备断开”，界面就会在“已连接”和“手柄已断开”
  /// 之间反复跳。所以这里按剩余时间重试，而不是直接返回 -1。
  int poll(int fd, Duration timeout) {
    _load();
    final pollFd = _pollFd ??= calloc<_PollFd>();
    final stopwatch = Stopwatch()..start();
    while (true) {
      pollFd.ref
        ..fd = fd
        ..events = pollIn
        ..revents = 0;
      final remaining = timeout.inMilliseconds - stopwatch.elapsedMilliseconds;
      final result = _poll!(pollFd, 1, remaining < 0 ? 0 : remaining);
      if (result >= 0) return pollFd.ref.revents;
      if (_errno() != _eintr) return -1;
      if (stopwatch.elapsedMilliseconds >= timeout.inMilliseconds) return 0;
    }
  }

  /// 读取事件数据。
  ///
  /// - 返回 `null`：读失败或读到 EOF（设备已被移除），调用方应视为断开。
  /// - 返回空列表：非阻塞 fd 暂时没有数据（或被信号打断），调用方应继续轮询。
  Uint8List? read(int fd, int maxBytes) {
    _load();
    final buffer = _readBuffer ??= calloc<Uint8>(bufferSize);
    final wanted = maxBytes < bufferSize ? maxBytes : bufferSize;
    final result = _read!(fd, buffer, wanted);
    if (result < 0) {
      final code = _errno();
      if (code == _eagain || code == _eintr) return Uint8List(0);
      return null;
    }
    // evdev 没有事件时不会返回 0；返回 0 说明设备节点已经结束。
    if (result == 0) return null;
    return Uint8List.fromList(buffer.asTypedList(result));
  }

  void close(int fd) {
    _load();
    _close!(fd);
  }

  void dispose() {
    final buffer = _readBuffer;
    if (buffer != null) {
      calloc.free(buffer);
      _readBuffer = null;
    }
    final pollFd = _pollFd;
    if (pollFd != null) {
      calloc.free(pollFd);
      _pollFd = null;
    }
  }
}
