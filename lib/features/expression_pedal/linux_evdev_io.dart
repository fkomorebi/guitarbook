import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linux_abs_info.dart';

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
      // open 是变参函数；不传 O_CREAT 时第三个参数会被忽略。
      final fd = _open!(nativePath, 0, _oNonBlock);
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

  int poll(int fd, Duration timeout) {
    _load();
    final pollFd = _pollFd ??= calloc<_PollFd>();
    pollFd.ref
      ..fd = fd
      ..events = pollIn
      ..revents = 0;
    final result = _poll!(pollFd, 1, timeout.inMilliseconds);
    if (result < 0) return -1;
    return pollFd.ref.revents;
  }

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
