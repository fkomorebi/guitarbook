import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev.dart';
import 'package:guitarbook/features/expression_pedal/linux_evdev_io.dart';

void main() {
  test('打开不存在的设备节点时返回 errno 2', () {
    if (!Platform.isLinux) return;
    final io = LinuxEvdevIo();
    addTearDown(io.dispose);
    final opened = io.open('/dev/guitarbook-does-not-exist');
    expect(opened.isOpen, isFalse);
    expect(opened.errorCode, 2);
  });

  test('能在普通文件上完成 poll / read / 事件解析', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_io_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/events.bin');
    await file.writeAsBytes(eventBytes(evAbs, absZ, 512));

    final io = LinuxEvdevIo();
    addTearDown(io.dispose);
    final opened = io.open(file.path);
    expect(opened.isOpen, isTrue);
    addTearDown(() => io.close(opened.fd));

    final buffer = EvdevEventBuffer();
    final events = <EvdevEvent>[];
    while (events.isEmpty) {
      final revents = io.poll(opened.fd, const Duration(seconds: 1));
      expect(revents & pollIn, isNonZero);
      final chunk = io.read(opened.fd, evdevEventSize * 4);
      expect(chunk, isNotNull);
      events.addAll(buffer.add(chunk!));
    }
    expect(events.single.type, evAbs);
    expect(events.single.code, absZ);
    expect(events.single.value, 512);
  });

  test('普通文件没有量程 ioctl，返回 null', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('guitarbook_io_');
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/events.bin');
    await file.writeAsBytes(eventBytes(evAbs, absZ, 1));

    final io = LinuxEvdevIo();
    addTearDown(io.dispose);
    final opened = io.open(file.path);
    expect(opened.isOpen, isTrue);
    addTearDown(() => io.close(opened.fd));
    expect(io.absRange(opened.fd, absZ), isNull);
  });
}

/// 按 64 位 Linux 的 `struct input_event` 布局生成一条事件。
List<int> eventBytes(int type, int code, int value) {
  final data = ByteData(evdevEventSize);
  data.setUint16(16, type, Endian.host);
  data.setUint16(18, code, Endian.host);
  data.setInt32(20, value, Endian.host);
  return data.buffer.asUint8List();
}
