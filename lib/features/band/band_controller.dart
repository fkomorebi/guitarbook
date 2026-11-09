import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drums/drum_pattern.dart';
import '../metronome/metronome_audio.dart';
import '../metronome/metronome_pattern.dart';
import 'chord_progression.dart';

/// 乐队 · 和弦进行：跟着鼓机的网格演奏一条和弦进行。
///
/// 和弦循环与鼓机循环共用同一条时间线：
///
/// 1. 小节长度用鼓机那一套公式换算（同一套采样率与拍号），两条循环逐样本同长；
/// 2. 启动时把鼓机在小节里的相位当作播放偏移，两边的小节线重合；
/// 3. 播放中每 400 ms 检查一次相位，偏差超过 120 ms 就重新对齐，不会互相漂移。
///
/// 切换进行或演奏方式时不会跳回第一小节：新的循环从当前相位接上。
class BandController extends ChangeNotifier {
  BandController({required this.audioFactory, this.drumPosition});

  /// 循环音频工厂；返回的对象要能按小节相位定位播放。
  final PositionedLoopAudio Function() audioFactory;

  /// 鼓机的播放位置；鼓机没有运行时返回 null。
  final Duration? Function()? drumPosition;

  /// 相位偏差超过该值就重新对齐到鼓机。
  static const Duration _alignTolerance = Duration(milliseconds: 120);

  /// 相位检查周期。
  static const Duration _alignInterval = Duration(milliseconds: 400);

  /// 当前和弦刷新周期。
  static const Duration _tickInterval = Duration(milliseconds: 100);

  /// 切换前淡出的时长，避免硬切产生咔哒声。
  static const Duration _fadeOutLength = Duration(milliseconds: 24);

  /// 淡出的步数。
  static const int _fadeSteps = 4;

  bool enabled = false;
  bool playing = false;
  String? error;

  double _volume = 0.8;
  double get volume => _volume;

  ChordProgression _progression = bandProgressions.first;
  ChordProgression get progression => _progression;

  ChordPlayStyle _style = ChordPlayStyle.pulse;
  ChordPlayStyle get style => _style;

  /// 当前正在响的和弦；没有播放时为 null。
  BandChord? _currentChord;
  BandChord? get currentChord => _currentChord;

  /// 当前和弦在进行的序号。
  int _currentChordIndex = 0;
  int get currentChordIndex => _currentChordIndex;

  int _bpm = 100;
  DrumMeter _meter = const DrumMeter(4, 4);
  int _swing = 0;

  PositionedLoopAudio? _audio;
  Timer? _timer;
  int _ticks = 0;
  Timer? _fadeTimer;
  Completer<void>? _fadeCompleter;
  bool _fadeCancelled = false;
  bool _rendering = false;
  bool _renderQueued = false;
  bool _enabling = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 同步鼓机的编排参数：速度、拍号与摇摆。
  ///
  /// 鼓机改动后和弦要按同一套网格重排，否则两条循环会错位。
  ///
  /// 只有速度、拍号或摇摆真的变了才重新渲染：鼓机每次敲鼓都会同步一次，
  /// 但和弦进行并不读鼓点，重渲染一次要重画整段进行，手感会卡。
  void setGroove({
    required int bpm,
    required DrumMeter meter,
    int swing = 0,
  }) {
    if (_disposed) return;
    final nextBpm = bpm > 0 ? bpm : _bpm;
    final changed =
        nextBpm != _bpm ||
        meter.beats != _meter.beats ||
        meter.denominator != _meter.denominator ||
        swing != _swing;
    _bpm = nextBpm;
    _meter = meter;
    _swing = swing;
    if (changed && enabled) unawaited(_rerender());
    _notify();
  }

  /// 切换和弦进行；正在播放时新的进行从当前相位接上。
  void setProgression(ChordProgression progression) {
    if (_disposed) return;
    _progression = progression;
    if (enabled) unawaited(_rerender());
    _notify();
  }

  /// 切换演奏方式；正在播放时新的编排从当前相位接上。
  void setStyle(ChordPlayStyle style) {
    if (_disposed) return;
    _style = style;
    if (enabled) unawaited(_rerender());
    _notify();
  }

  /// 和弦音量，0~1。
  void setVolume(double volume) {
    if (_disposed || !volume.isFinite) return;
    _volume = volume.clamp(0, 1);
    try {
      _audio?.setGain(_volume);
    } catch (e) {
      error = '和弦音量调节失败：$e';
    }
    _notify();
  }

  /// 开启和弦进行：准备循环并与鼓机对齐。
  Future<void> enable() async {
    if (_disposed || enabled || _enabling) return;
    _enabling = true;
    error = null;
    try {
      final audio = _audio ??= audioFactory();
      try {
        await audio.unlock();
      } catch (_) {
        // 解锁失败时由播放阶段给出提示。
      }
      if (_disposed) return;
      await audio.prepare(_render());
      if (_disposed) return;
      audio.setGain(_volume);
      // 从鼓机在小节里的相位开始，两条循环的小节线重合。
      audio.playAt(Duration(microseconds: _drumPhaseMicros()));
      playing = true;
      enabled = true;
      _startTimer();
    } catch (e) {
      playing = false;
      enabled = false;
      error = '和弦进行启动失败：$e';
    } finally {
      _enabling = false;
    }
    _notify();
  }

  /// 停止和弦进行：释放循环音频。
  Future<void> disable() async {
    _timer?.cancel();
    _timer = null;
    _cancelFade();
    playing = false;
    enabled = false;
    _currentChord = null;
    _currentChordIndex = 0;
    final audio = _audio;
    _audio = null;
    if (audio != null) {
      try {
        audio.silence();
      } catch (_) {
        // 设备已经消失时忽略。
      }
      try {
        await audio.clear();
      } catch (_) {
        // 已经清空时忽略。
      }
      try {
        await audio.dispose();
      } catch (_) {
        // 已经释放时忽略。
      }
    }
    _notify();
  }

  /// 按当前的进行与演奏方式渲染一条循环。
  MetronomePattern _render() => renderChordProgression(
    bpm: _bpm,
    progression: _progression,
    style: _style,
    meter: _meter,
    swing: _swing,
  );

  /// 重新渲染循环；正在播放时保持当前相位。
  Future<void> _rerender() async {
    if (_disposed) return;
    if (_rendering) {
      _renderQueued = true;
      return;
    }
    _rendering = true;
    try {
      var again = true;
      while (again && !_disposed) {
        again = _renderQueued;
        _renderQueued = false;
        await _swapPattern();
      }
    } finally {
      _rendering = false;
    }
  }

  /// 换掉循环内容：从当前相位接上，切换前先把音量淡下去。
  Future<void> _swapPattern() async {
    final audio = _audio;
    if (_disposed || audio == null || !enabled) return;
    final phase = _currentPhaseMicros();
    try {
      final pattern = _render();
      // 淡出与准备并行：音量先降下去，新循环准备好后再从原相位接上。
      final faded = _fadeOut(audio);
      await audio.clear();
      await audio.prepare(pattern);
      await faded;
      // 等待期间可能已经停止或释放音频。
      if (_disposed || !enabled || _audio != audio) return;
      audio.setGain(_volume);
      audio.playAt(Duration(microseconds: phase));
      error = null;
    } catch (e) {
      error = '和弦进行切换失败：$e';
    }
    _notify();
  }

  /// 切换前把音量快速降到 0，减少硬切的咔哒声。
  Future<void> _fadeOut(PositionedLoopAudio audio) async {
    final start = _volume;
    if (start <= 0) return;
    _fadeCancelled = false;
    for (var i = 1; i <= _fadeSteps; i++) {
      if (_disposed || _fadeCancelled) return;
      try {
        audio.setGain(start * (1 - i / _fadeSteps));
      } catch (_) {
        return;
      }
      await _wait(_fadeOutLength ~/ _fadeSteps);
      // 淡出被取消后不要再排下一个等待，否则会留下没人管的定时器。
      if (_fadeCancelled) return;
    }
  }

  /// 等待一小段时间；等待可以被取消，方便停止时立刻收手。
  Future<void> _wait(Duration duration) {
    final completer = Completer<void>();
    _fadeTimer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    _fadeCompleter = completer;
    return completer.future;
  }

  /// 取消正在进行的淡出等待。
  void _cancelFade() {
    final timer = _fadeTimer;
    final completer = _fadeCompleter;
    _fadeTimer = null;
    _fadeCompleter = null;
    // 让淡出循环立刻收手：取消之后再排新的等待会留下没人管的定时器。
    _fadeCancelled = true;
    timer?.cancel();
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// 每 100 ms 刷新一次当前和弦，每 400 ms 检查一次与鼓机的相位。
  void _startTimer() {
    _timer?.cancel();
    _ticks = 0;
    _timer = Timer.periodic(_tickInterval, (_) {
      _ticks++;
      _updateChord();
      final steps = _alignInterval.inMilliseconds ~/ _tickInterval.inMilliseconds;
      if (_ticks % steps == 0) _checkAlignment();
    });
  }

  /// 按播放位置算出当前小节与当前和弦。
  void _updateChord() {
    if (_disposed || !playing) return;
    final audio = _audio;
    if (audio == null) return;
    final position = _safePosition(audio);
    if (position == null) return;
    final bar = _barMicros;
    if (bar <= 0) return;
    final bars = _progression.bars;
    if (bars <= 0) return;
    final perChord = _progression.barsPerChord <= 0
        ? 1
        : _progression.barsPerChord;
    final barIndex = (position.inMicroseconds ~/ bar) % bars;
    final chordIndex = barIndex ~/ perChord;
    if (chordIndex < 0 || chordIndex >= _progression.chords.length) return;
    final chord = _progression.chordAt(chordIndex);
    if (chordIndex == _currentChordIndex && identical(chord, _currentChord)) {
      return;
    }
    _currentChordIndex = chordIndex;
    _currentChord = chord;
    _notify();
  }

  /// 检查和弦与鼓机的相位；偏差过大就重新对齐。
  void _checkAlignment() {
    if (_disposed || !playing) return;
    final drum = _drumPosition();
    if (drum == null) return;
    final bar = _barMicros;
    if (bar <= 0) return;
    final audio = _audio;
    if (audio == null) return;
    final position = _safePosition(audio);
    if (position == null) return;
    final drumPhase = drum.inMicroseconds % bar;
    final ownPhase = position.inMicroseconds % bar;
    if ((drumPhase - ownPhase).abs() <= _alignTolerance.inMicroseconds) return;
    try {
      // 保住进行里的小节序号，只把相位拉回鼓机，避免把进行重置到第一小节。
      final bars = _progression.bars <= 0 ? 1 : _progression.bars;
      final loop = _loopMicros;
      final barIndex = (position.inMicroseconds ~/ bar) % bars;
      final offset = loop <= 0 ? drumPhase : (barIndex * bar + drumPhase) % loop;
      audio.playAt(Duration(microseconds: offset));
    } catch (e) {
      error = '和弦进行重新对齐失败：$e';
      _notify();
    }
  }

  /// 鼓机在小节里的相位（微秒）；鼓机没有运行时为 0。
  int _drumPhaseMicros() {
    final bar = _barMicros;
    if (bar <= 0) return 0;
    final drum = _drumPosition();
    if (drum == null) return 0;
    return drum.inMicroseconds % bar;
  }

  /// 当前循环在整条进行里的相位（微秒），切换时用它接上。
  ///
  /// 对整条进行取模，而不是只对小节取模：这样换演奏方式时进行里的小节序号
  /// 会被保住，和弦不会跳回第一个和弦。
  int _currentPhaseMicros() {
    final loop = _loopMicros;
    if (loop <= 0) return 0;
    final audio = _audio;
    if (audio != null) {
      final position = _safePosition(audio);
      if (position != null) return position.inMicroseconds % loop;
    }
    final drum = _drumPosition();
    if (drum != null) return drum.inMicroseconds % loop;
    return 0;
  }

  /// 读取播放位置；音频已经停下时返回 null。
  Duration? _safePosition(PositionedLoopAudio audio) {
    try {
      return audio.position;
    } catch (_) {
      return null;
    }
  }

  /// 鼓机的播放位置；鼓机没有运行时返回 null。
  Duration? _drumPosition() {
    final read = drumPosition;
    if (read == null) return null;
    try {
      return read();
    } catch (_) {
      return null;
    }
  }

  /// 一小节的长度（微秒），与鼓机循环逐样本一致。
  int get _barMicros {
    final rate = (48000 / _bpm).round() * _bpm;
    if (rate <= 0) return 0;
    final quarterFrames = rate * 60 ~/ _bpm;
    final beatFrames = _meter.denominator == 8
        ? quarterFrames ~/ 2
        : quarterFrames;
    return (beatFrames * _meter.beats * 1000000) ~/ rate;
  }

  /// 整条循环的长度（微秒）：进行里的若干小节。
  int get _loopMicros {
    final bar = _barMicros;
    if (bar <= 0) return 0;
    final bars = _progression.bars <= 0 ? 1 : _progression.bars;
    return bar * bars;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(disable());
    super.dispose();
  }
}
