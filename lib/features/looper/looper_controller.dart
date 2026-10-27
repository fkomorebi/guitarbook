import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../metronome/metronome_audio.dart';
import '../metronome/metronome_pattern.dart';
import 'loop_audio.dart';
import 'loop_samples.dart';

class _Layer {
  _Layer(this.samples, this.audio);
  final Float32List samples;
  final PositionedLoopAudio audio;
}

class LooperController extends ChangeNotifier {
  LooperController(this.input, this.outputFactory);
  final LoopInput input;
  final PositionedLoopAudio Function() outputFactory;
  final List<_Layer> _layers = [];
  StreamSubscription<Uint8List>? _subscription;
  Timer? _watchdog;
  final Stopwatch _lastInput = Stopwatch();
  Future<void> _queue = Future.value();
  LoopTake? _take;
  PositionedLoopAudio? _armedAudio;
  int? _takeOffset;
  int _generation = 0;
  bool _disposed = false;
  bool busy = false;
  bool playing = false;
  bool capturing = false;
  String? error;
  int compensationMs = 0;
  double _playbackGain = 1;
  double get playbackGain => _playbackGain;

  void setPlaybackGain(double gain) {
    if (_disposed || !gain.isFinite) return;
    _playbackGain = gain.clamp(0, 4);
    try {
      for (final layer in _layers) {
        layer.audio.setGain(_playbackGain);
      }
    } catch (_) {
      _inputFailed('调节回放音量失败，请检查输出设备后重试。');
    }
    _notify();
  }

  InputDevice? device;
  List<InputDevice> devices = [];

  LoopInputMeter inputMeter = LoopInputMeter();

  bool get recording => _take != null;
  int get layers => _layers.length;
  int get frames => _layers.isEmpty ? 0 : _layers.first.samples.length;
  double get seconds => frames / loopSampleRate;
  double get recordedSeconds => (_take?.count ?? 0) / loopSampleRate;
  Duration get position => _layers.isEmpty || !playing
      ? Duration.zero
      : _layers.first.audio.position;
  Future<void> get settled => _queue;
  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _enqueue(Future<void> Function(int generation) action) {
    if (_disposed || busy) return;
    final generation = _generation;
    busy = true;
    error = null;
    _notify();
    _queue = _queue.then((_) async {
      try {
        await action(generation);
      } catch (e) {
        if (_current(generation)) {
          stop();
          error = e is StateError
              ? e.message.toString()
              : '音频操作失败，请检查输入设备、权限和输出后重试。';
        }
      } finally {
        if (_current(generation)) {
          busy = false;
          _notify();
        }
      }
    });
  }

  Future<void> refreshDevices() async {
    if (_disposed || capturing || busy) return;
    final generation = _generation;
    try {
      final found = await input.devices();
      if (!_current(generation) || capturing || busy) return;
      devices = found;
      if (device != null && !found.any((d) => d.id == device!.id)) {
        device = null;
      }
    } catch (_) {
      if (!_current(generation)) return;
      error = '无法列出录音设备，请检查声卡连接后刷新重试。';
    }
    _notify();
  }

  Future<void> _capture(int generation) async {
    if (capturing) return;
    final stream = await input.start(device);
    if (!_current(generation)) {
      await input.stop();
      return;
    }
    inputMeter = LoopInputMeter();
    capturing = true;
    _lastInput
      ..reset()
      ..start();
    _subscription = stream.listen(
      (bytes) {
        if (!_current(generation)) return;
        if (bytes.isNotEmpty) _lastInput.reset();
        inputMeter.add(bytes);
        final take = _take;
        if (take == null) return;
        try {
          if (_takeOffset == null) {
            // Estimate the first sample's capture position from block duration.
            final blockDuration = Duration(
              microseconds: bytes.length ~/ 2 * 1000000 ~/ loopSampleRate,
            );
            _takeOffset = frames == 0
                ? 0
                : phaseFrame(position - blockDuration, frames, compensationMs);
          }
          take.add(bytes);
          if (take.count == take.limit && !busy) mainPedal();
        } catch (_) {
          _inputFailed('读取循环进度失败，请检查音频设备后重试。');
        }
      },
      onError: (Object _) => _inputFailed('录音中断，请检查输入设备后重试。'),
      onDone: () {
        if (capturing) _inputFailed('录音输入已结束，请重新开始。');
      },
    );
    _watchdog = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_lastInput.elapsed > const Duration(seconds: 5)) {
        _inputFailed('5 秒内未收到音频，请检查输入设备后重试。');
      } else if (playing) {
        try {
          position;
        } catch (_) {
          _inputFailed('循环播放已中断，请检查输出设备后重试。');
        }
      }
      _notify();
    });
  }

  void _inputFailed(String message) {
    if (_disposed) return;
    stop();
    error = message;
    _notify();
  }

  // Unlock synchronously inside the initiating gesture, including on Web.
  Future<Object?> _unlock(List<PositionedLoopAudio> outputs) => Future.wait(
    outputs.map((audio) => Future<void>.sync(audio.unlock)),
  ).then<Object?>((_) => null, onError: (Object e) => e);

  void mainPedal() {
    if (_disposed || busy) return;
    if (recording) {
      final take = _take!;
      if (take.count < loopSampleRate * .3) {
        error = '录音至少需要 0.3 秒，请继续演奏后再踩一次。';
        _notify();
        return;
      }
      _take = null;
      final length = frames == 0 ? take.count : frames;
      final samples = take.finish(length: length, offset: _takeOffset ?? 0);
      final audio = _armedAudio!;
      _armedAudio = null;
      final unlocked = _unlock([audio]);
      _enqueue((generation) async {
        var accepted = false;
        try {
          final failure = await unlocked;
          if (failure != null) throw failure;
          if (!_current(generation)) return;
          await audio.prepare(
            MetronomePattern.rendered(
              bpm: 100,
              beats: 4,
              sampleRate: loopSampleRate,
              framesPerBeat: length ~/ 4,
              samples: samples,
            ),
          );
          if (!_current(generation)) return;
          final offset = frames == 0
              ? Duration.zero
              : Duration(
                  microseconds:
                      position.inMicroseconds %
                      (length * 1000000 ~/ loopSampleRate),
                );
          audio.setGain(_playbackGain);
          audio.playAt(offset);
          _layers.add(_Layer(samples, audio));
          accepted = true;
          playing = true;
        } finally {
          if (!accepted) await audio.dispose();
        }
      });
    } else if (!playing && layers > 0) {
      resume();
    } else if (layers >= maxLoopLayers) {
      error = '最多 $maxLoopLayers 层，可先撤销最近一层或清空。';
      _notify();
    } else {
      final audio = outputFactory();
      _armedAudio = audio;
      final unlocked = _unlock([audio]);
      _enqueue((generation) async {
        final failure = await unlocked;
        if (failure != null) throw failure;
        if (!_current(generation)) return;
        await _capture(generation);
        if (!_current(generation) || !capturing) return;
        _take = LoopTake(frames == 0 ? maxLoopFrames : frames);
        _takeOffset = null;
      });
    }
  }

  void resume() {
    if (_disposed || busy || layers == 0 || playing) return;
    final unlocked = _unlock([for (final layer in _layers) layer.audio]);
    _enqueue((generation) async {
      final failure = await unlocked;
      if (failure != null) throw failure;
      if (!_current(generation)) return;
      await _capture(generation);
      if (!_current(generation) || !capturing) return;
      for (final layer in _layers) {
        layer.audio.playAt(Duration.zero);
      }
      playing = true;
    });
  }

  void togglePlayback() {
    if (playing || recording || busy || capturing) {
      stop();
    } else {
      resume();
    }
  }

  void stop() {
    if (_disposed) return;
    ++_generation;
    _take = null;
    playing = false;
    capturing = false;
    busy = false;
    _watchdog?.cancel();
    _lastInput.stop();
    for (final layer in _layers) {
      try {
        layer.audio.silence();
      } catch (_) {}
    }
    final armed = _armedAudio;
    _armedAudio = null;
    final subscription = _subscription;
    _subscription = null;
    _queue = _queue
        .then((_) async {
          await subscription?.cancel();
          await input.stop();
          await armed?.dispose();
        })
        .catchError((Object _) {});
    _notify();
  }

  void undo() {
    if (_disposed || busy || recording || layers == 0) return;
    // Keep the base clock while removing overdubs; the base can be cleared.
    if (layers == 1) {
      clear();
      return;
    }
    final layer = _layers.removeLast();
    try {
      layer.audio.silence();
    } catch (_) {}
    _queue = _queue
        .then((_) => layer.audio.dispose())
        .catchError((Object _) {});
    _notify();
  }

  void clear() {
    if (_disposed) return;
    stop();
    final old = List<_Layer>.of(_layers);
    _layers.clear();
    error = null;
    _queue = _queue
        .then((_) async {
          for (final layer in old) {
            await layer.audio.dispose();
          }
        })
        .catchError((Object _) {});
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
    _queue = _queue.then((_) => input.dispose()).catchError((Object _) {});
    super.dispose();
  }
}
