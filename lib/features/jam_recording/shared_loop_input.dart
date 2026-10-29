import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../looper/loop_audio.dart';

/// Independent leases on one physical input, serialized across async starts.
class SharedLoopInput {
  SharedLoopInput(this.source);
  final LoopInput source;
  final Set<_InputLease> _leases = {};
  StreamSubscription<Uint8List>? _subscription;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  LoopInput lease() => _InputLease(this);

  Future<void> _serialize(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> dispose() => _serialize(() async {
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    for (final lease in _leases.toList()) {
      unawaited(lease._stream?.close());
      lease._stream = null;
    }
    _leases.clear();
    await source.dispose();
  });
}

class _InputLease implements LoopInput {
  _InputLease(this.owner);
  final SharedLoopInput owner;
  StreamController<Uint8List>? _stream;
  bool _disposed = false;
  @override
  Future<List<InputDevice>> devices() => owner.source.devices();
  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async {
    late Stream<Uint8List> result;
    await owner._serialize(() async {
      if (_disposed || owner._disposed) throw StateError('录音输入已关闭。');
      if (_stream != null) throw StateError('录音输入已启动。');
      if (owner._leases.isEmpty) {
        final input = await owner.source.start(device);
        owner._subscription = input.listen(
          (bytes) {
            for (final lease in owner._leases.toList()) {
              lease._stream?.add(bytes);
            }
          },
          onError: (Object error, StackTrace stack) {
            for (final lease in owner._leases.toList()) {
              lease._stream?.addError(error, stack);
            }
          },
          onDone: () {
            for (final lease in owner._leases.toList()) {
              unawaited(lease._stream?.close());
            }
          },
        );
      }
      final stream = _stream = StreamController<Uint8List>();
      owner._leases.add(this);
      result = stream.stream;
    });
    return result;
  }

  @override
  Future<void> stop() => owner._serialize(() async {
    if (!owner._leases.remove(this)) return;
    final stream = _stream;
    _stream = null;
    unawaited(stream?.close());
    if (owner._leases.isEmpty) {
      await owner._subscription?.cancel();
      owner._subscription = null;
      await owner.source.stop();
    }
  });
  @override
  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }
}
