import 'dart:async';

import 'package:flutter/foundation.dart';

import 'metronome_audio.dart';
import 'metronome_pattern.dart';

class MetronomeController extends ChangeNotifier {
  MetronomeController(this._audio, {this.patternBuilder});

  final MetronomePattern Function(int bpm)? patternBuilder;

  final MetronomeAudio _audio;
  final _visualClock = Stopwatch();
  Future<void> _queue = Future<void>.value();
  Timer? _displayTimer;
  int _generation = 0;
  bool _disposed = false;
  int bpm = 100;
  int beats = 4;

  /// 拍分母：4 表示一拍是一个四分音符，8 表示一拍是一个八分音符。
  ///
  /// bpm 恒为每分钟四分音符数，只有拍号才决定一拍有多长；节拍器页面保持默认的 4。
  int beatDenominator = 4;

  int beat = 0;
  bool sound = true;
  bool accent = true;
  bool running = false;
  bool preparing = false;
  String? error;
  double _volume = 1;
  double get volume => _volume;

  void setVolume(double volume) {
    if (_disposed || !volume.isFinite) return;
    _volume = volume.clamp(0, 1);
    try {
      _audio.setGain(_volume);
    } catch (_) {
      _fail();
      return;
    }
    notifyListeners();
  }

  bool _current(int generation) =>
      !_disposed && running && generation == _generation;

  void _silence() {
    try {
      _audio.silence();
    } catch (_) {
      // Cleanup is still queued if the device has disappeared.
    }
  }

  void start() {
    if (_disposed) return;
    final generation = ++_generation;
    _displayTimer?.cancel();
    _visualClock.stop();
    _silence();
    running = true;
    preparing = sound;
    error = null;
    beat = sound ? 0 : 1;
    // Capture errors immediately: a previous load may still occupy the queue.
    final unlocked = sound
        ? Future<void>.sync(
            _audio.unlock,
          ).then<Object?>((_) => null, onError: (Object error) => error)
        : Future<Object?>.value();
    final patternBpm = bpm;
    final patternBeats = beats;
    final patternAccent = accent;
    final useAudio = sound;
    if (!useAudio) {
      _visualClock
        ..reset()
        ..start();
      _watch(generation);
    }
    notifyListeners();
    _queue = _queue
        .then((_) async {
          await _audio.clear();
          if (!_current(generation) || !useAudio) return;
          final unlockError = await unlocked;
          if (unlockError != null) throw unlockError;
          if (!_current(generation)) return;
          await _audio.prepare(
            patternBuilder?.call(patternBpm) ??
                MetronomePattern(
                  bpm: patternBpm,
                  beats: patternBeats,
                  accent: patternAccent,
                ),
          );
          // Stop/reconfigure/background can happen while loading native audio.
          if (!_current(generation)) {
            await _audio.clear();
            return;
          }
          _audio.setGain(_volume);
          _audio.play();
          preparing = false;
          beat = 1;
          _watch(generation);
          notifyListeners();
        })
        .catchError((Object failure) {
          if (_current(generation)) _fail();
        });
  }

  void _watch(int generation) {
    // This timer only redraws the UI. It never triggers or queues audio.
    _displayTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_current(generation)) return;
      try {
        final position = sound ? _audio.position : _visualClock.elapsed;
        final next = _beatIndex(position) % beats + 1;
        if (next != beat) {
          beat = next;
          notifyListeners();
        }
      } catch (_) {
        _fail();
      }
    });
  }

  /// 播放位置落在第几拍（从 0 开始）。
  ///
  /// bpm 是每分钟四分音符数，一拍的长度按拍分母缩放：四分音符一拍为 60/bpm 秒，
  /// 八分音符一拍减半，这样 6/8、7/8 的拍点能落在正确的位置。
  int _beatIndex(Duration position) =>
      position.inMicroseconds * bpm * beatDenominator ~/ 240000000;

  void _fail() {
    stop();
    error = '声音播放失败，请检查音频设备后重试，或关闭声音使用可视节拍。';
    notifyListeners();
  }

  void stop() {
    if (_disposed) return;
    ++_generation;
    _displayTimer?.cancel();
    _visualClock.stop();
    _silence();
    running = false;
    preparing = false;
    beat = 0;
    _queue = _queue.then((_) => _audio.clear()).catchError((Object _) {});
    notifyListeners();
  }

  void configure({
    int? bpm,
    int? beats,
    int? beatDenominator,
    bool? sound,
    bool? accent,
  }) {
    this.bpm = (bpm ?? this.bpm).clamp(30, 240);
    this.beats = (beats ?? this.beats).clamp(1, 12);
    this.beatDenominator = (beatDenominator ?? this.beatDenominator).clamp(
      2,
      8,
    );
    this.sound = sound ?? this.sound;
    this.accent = accent ?? this.accent;
    if (running) {
      start();
    } else {
      notifyListeners();
    }
  }

  /// Includes pending loading and resource cleanup; useful for lifecycle tests.
  Future<void> get settled => _queue;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _displayTimer?.cancel();
    _visualClock.stop();
    _silence();
    _queue = _queue.then((_) => _audio.dispose()).catchError((Object _) {});
    super.dispose();
  }
}
