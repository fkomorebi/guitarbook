import 'dart:async';

import 'package:flutter/foundation.dart';

import '../looper/loop_audio.dart';
import 'recording_audio.dart';
import 'recording_buffer.dart';

class JamRecorder extends ChangeNotifier {
  JamRecorder(this.input, this.outputs);
  final LoopInput input;
  final Set<RecordingAudio> outputs;
  RecordingBuffer? buffer;
  int memoryMiB = 32;
  bool recording = false;
  bool starting = false;
  String? error;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _watchdog;
  final _lastInput = Stopwatch();
  int _generation = 0;
  bool _disposed = false;
  Future<void> _queue = Future.value();

  Future<void> start() async {
    if (_disposed || starting || recording) return;
    final generation = ++_generation;
    starting = true;
    error = null;
    notifyListeners();
    _queue = _queue.then((_) => _start(generation));
    await _queue;
  }

  Future<void> _start(int generation) async {
    try {
      if (_disposed || generation != _generation) return;
      final next = RecordingBuffer(memoryMiB * 1024 * 1024);
      final stream = await input.start(null);
      if (_disposed || generation != _generation) {
        await input.stop();
        return;
      }
      buffer = next;
      int? pendingByte;
      recording = true;
      _lastInput
        ..reset()
        ..start();
      _subscription = stream.listen(
        (bytes) {
          if (!recording || generation != _generation) return;
          try {
            if (bytes.isEmpty) return;
            _lastInput.reset();
            final count = (bytes.length + (pendingByte == null ? 0 : 1)) ~/ 2;
            final sources = [for (final output in outputs) output.block(count)];
            final pcm = ByteData.sublistView(bytes);
            var byteOffset = 0;
            for (var frame = 0; frame < count; frame++) {
              int sample;
              if (pendingByte != null) {
                sample = pendingByte! | (bytes[byteOffset++] << 8);
                if (sample >= 32768) sample -= 65536;
                pendingByte = null;
              } else {
                sample = pcm.getInt16(byteOffset, Endian.little);
                byteOffset += 2;
              }
              var mixed = sample / 32768;
              for (final source in sources) {
                mixed += source(frame);
              }
              next.add(mixed);
            }
            if (byteOffset < bytes.length) pendingByte = bytes[byteOffset];
          } catch (_) {
            _fail('混音失败，已保留此前录音，请检查音频设备后重试。');
          }
        },
        onError: (Object failure) {
          _fail(failure is StateError ? failure.message.toString() : '录音输入中断。');
        },
        onDone: () {
          if (recording) _fail('录音输入已结束，已保留此前录音。');
        },
      );
      _watchdog = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (_lastInput.elapsed > const Duration(seconds: 5)) {
          _fail('5 秒未收到演奏输入，已停止录音。');
        } else if (!_disposed) {
          notifyListeners();
        }
      });
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = failure is StateError
            ? failure.message.toString()
            : '无法开始录音，请检查权限和输入设备。';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        starting = false;
        notifyListeners();
      }
    }
  }

  void _fail(String message) {
    if (_disposed) return;
    stop();
    error = message;
    notifyListeners();
  }

  void stop() {
    if (_disposed) return;
    ++_generation;
    recording = starting = false;
    _watchdog?.cancel();
    _lastInput.stop();
    final subscription = _subscription;
    _subscription = null;
    _queue = _queue
        .then((_) async {
          await subscription?.cancel();
          await input.stop();
        })
        .catchError((Object _) {});
    notifyListeners();
  }

  Future<void> get settled => _queue;

  @override
  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    buffer = null;
    _queue = _queue.then((_) => input.dispose()).catchError((Object _) {});
    super.dispose();
  }
}
