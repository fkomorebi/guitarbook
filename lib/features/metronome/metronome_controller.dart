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
  int beat = 0;
  bool sound = true;
  bool accent = true;
  bool running = false;
  bool preparing = false;
  String? error;

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
        final next = (position.inMicroseconds * bpm ~/ 60000000) % beats + 1;
        if (next != beat) {
          beat = next;
          notifyListeners();
        }
      } catch (_) {
        _fail();
      }
    });
  }

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

  void configure({int? bpm, int? beats, bool? sound, bool? accent}) {
    this.bpm = (bpm ?? this.bpm).clamp(30, 240);
    this.beats = (beats ?? this.beats).clamp(1, 12);
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
