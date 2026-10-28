import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'effects_mobile_transport.dart';

/// Controls, meters and bounded Looper PCM use a mobile channel or desktop pipe.
class EffectsBackend {
  bool get mobile => Platform.isAndroid || Platform.isIOS;
  bool get supported => mobile || Platform.isLinux || Platform.isWindows;
  bool get supportsVst3 => !mobile;
  bool get supportsDeviceSettings => !mobile;
  EffectsMobileTransport? _mobileTransport;
  Process? _process;
  Future<void>? _launching;
  int _nextId = 0;
  bool _disposed = false;
  Object? _exitError;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  Future<void> _launch() async {
    if (!supported) throw UnsupportedError('此平台暂不支持实时效果器。');
    if (_disposed) throw StateError('效果器已关闭。');
    if (_process != null) return;
    final separator = Platform.pathSeparator;
    final directory = File(Platform.resolvedExecutable).parent.path;
    final name = 'guitarbook_effects_host${Platform.isWindows ? '.exe' : ''}';
    final path =
        Platform.environment['GUITARBOOK_EFFECTS_HOST'] ??
        '$directory$separator$name';
    if (!File(path).existsSync()) {
      throw StateError(
        '未找到原生效果器引擎，请构建桌面应用，或通过 GUITARBOOK_EFFECTS_HOST 指定引擎路径。',
      );
    }
    final process = await Process.start(path, const []);
    if (_disposed) {
      process.kill();
      throw StateError('效果器已关闭。');
    }
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final response = jsonDecode(line);
            if (response is! Map<String, dynamic>) return;
            final completer = _pending.remove(response['id']);
            if (completer == null) return;
            if (response['error'] != null) {
              completer.completeError(StateError(response['error'].toString()));
            } else {
              completer.complete(
                Map<String, dynamic>.from(response['result'] as Map),
              );
            }
          } on FormatException {
            // Some third-party plugins write diagnostics to stdout.
          }
        }, onError: (Object error) => _fail(error));
    // Drain plugin diagnostics without retaining unbounded output.
    process.stderr.listen((_) {});
    unawaited(
      process.exitCode.then((code) {
        if (_process != process) return;
        _process = null;
        final error = StateError('效果器引擎已退出（$code），请重新连接。');
        if (_pending.isEmpty) _exitError = error;
        _fail(error);
      }),
    );
  }

  void _fail(Object error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (_disposed) throw StateError('效果器已关闭。');
    if (mobile) {
      return (_mobileTransport ??= EffectsMobileTransport()).send(
        command,
        arguments,
      );
    }
    // Surface an idle-time plugin crash before a status poll can silently
    // replace the lost chain with a freshly launched empty host.
    if (command == 'status' && _exitError != null) {
      final error = _exitError!;
      _exitError = null;
      throw error;
    }
    _exitError = null;
    await (_launching ??= _launch()).whenComplete(() => _launching = null);
    final process = _process;
    if (process == null || _disposed) throw StateError('效果器引擎未连接。');
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      process.stdin.writeln(
        jsonEncode({'id': id, 'command': command, ...arguments}),
      );
      return await completer.future.timeout(
        Duration(seconds: command == 'load' ? 60 : 10),
      );
    } on TimeoutException {
      // A hung plugin must not keep monitoring after the UI reports failure.
      _process = null;
      process.kill();
      _fail(StateError('效果器引擎无响应，请重新连接；当前效果链已释放。'));
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    if (mobile) {
      await _mobileTransport?.dispose();
      return;
    }
    final process = _process;
    _process = null;
    _fail(StateError('效果器已关闭。'));
    if (process != null) {
      try {
        await process.stdin.close().timeout(const Duration(seconds: 2));
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // A crashed plugin may have already closed its input pipe.
        process.kill();
      }
    }
  }
}
