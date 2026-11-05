import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drums/drum_pattern.dart';
import '../looper/loop_audio.dart';
import '../metronome/metronome_audio.dart';
import '../metronome/metronome_pattern.dart';
import 'bass_pattern.dart';
import 'chord_detector.dart';

/// 智能base：跟着吉他输入的和弦，在鼓机的网格上自动编排一条低音线。
///
/// 控制器分三步工作：
///
/// 1. 从工作台共享的输入通道取一段 PCM，做和弦识别；
/// 2. 用鼓机当前的 bpm、拍号、底鼓落点把和弦编排成一小节的低音；
/// 3. 让低音循环与鼓机循环共用同一套小节长度和相位，两者不会漂移。
///
/// 低音循环的小节长度与鼓机循环逐样本相同（同一套换算公式），
/// 因此只要在启动时对齐相位，之后两条循环会一直同步。
class SmartBassController extends ChangeNotifier {
  SmartBassController({
    required this.input,
    required this.audioFactory,
    this.drumPosition,
  });

  /// 工作台共享的输入通道：与 Looper、即兴录音共用同一路麦克风。
  final LoopInput input;

  /// 低音播放器的工厂；返回的对象要能按小节相位定位播放。
  final PositionedLoopAudio Function() audioFactory;

  /// 鼓机的播放位置；鼓机没有运行时返回 null。
  final Duration? Function()? drumPosition;

  /// 工作台输入通道的采样率（48 kHz PCM16 单声道）。
  static const int inputSampleRate = 48000;

  /// 和弦识别窗口长度：48 kHz 下约 85 ms。
  static const int windowSize = 4096;

  /// 两次识别之间前进的样本数，约 43 ms。
  static const int _hopSize = 2048;

  /// 相位偏差超过该值就重新对齐到鼓机。
  static const Duration _alignTolerance = Duration(milliseconds: 120);

  /// 相位检查周期。
  static const Duration _alignInterval = Duration(milliseconds: 400);

  /// 连续识别到同一个和弦几次才认为稳定。
  static const int _stableHits = 2;

  /// 切换前淡出的时长，避免硬切产生咔哒声。
  static const Duration _fadeOutLength = Duration(milliseconds: 24);

  bool enabled = false;
  bool listening = false;
  bool playing = false;
  String? error;

  /// 最近一次识别到的和弦。
  ChordDetection? chord;

  double _volume = 0.9;
  double get volume => _volume;

  BassStyle _style = BassStyle.followKick;
  BassStyle get style => _style;

  int _bpm = 100;
  DrumMeter _meter = const DrumMeter(4, 4);
  List<List<bool>> _hits = const <List<bool>>[];
  int _swing = 0;

  StreamSubscription<Uint8List>? _subscription;
  PositionedLoopAudio? _audio;
  Timer? _alignTimer;
  Timer? _swapTimer;

  final Float32List _window = Float32List(windowSize);
  int _writeIndex = 0;
  int _received = 0;
  int _analysed = 0;

  ChordDetection? _candidate;
  int _candidateHits = 0;

  MetronomePattern? _pendingPattern;
  int _pendingOffsetMicros = 0;

  bool _disposed = false;
  int _generation = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 同步鼓机的编排参数：速度、拍号、底鼓落点与摇摆。
  ///
  /// 鼓机改动后低音要按同一套网格重排，否则两条循环会错位。
  void setGroove({
    required int bpm,
    required DrumMeter meter,
    required List<List<bool>> hits,
    int swing = 0,
  }) {
    if (_disposed) return;
    _bpm = bpm;
    _meter = meter;
    _hits = hits;
    _swing = swing;
    final current = chord;
    if (current == null) return;
    _queuePattern(current);
  }

  /// 切换低音风格；新的编排在下一拍生效。
  void setStyle(BassStyle style) {
    if (_disposed || style == _style) return;
    _style = style;
    final current = chord;
    if (current == null) {
      _notify();
      return;
    }
    _queuePattern(current);
    _notify();
  }

  /// 低音音量，0~1。
  void setVolume(double volume) {
    if (_disposed || !volume.isFinite) return;
    _volume = volume.clamp(0, 1);
    try {
      _audio?.setGain(_volume);
    } catch (_) {
      error = '调节低音音量失败，请检查音频设备后重试。';
    }
    _notify();
  }

  /// 开启智能base：开始监听输入，等待识别出和弦。
  Future<void> enable() async {
    if (_disposed || enabled) return;
    enabled = true;
    error = null;
    final generation = ++_generation;
    // 先解锁音频：网页端必须在用户点击的那一刻恢复音频上下文。
    final audio = _audio ??= audioFactory();
    try {
      await audio.unlock();
    } catch (_) {
      // 解锁失败时由播放阶段给出提示。
    }
    if (!_current(generation)) return;
    try {
      final stream = await input.start(null);
      if (!_current(generation)) {
        await input.stop();
        return;
      }
      listening = true;
      _subscription = stream.listen(_onBytes);
      _alignTimer = Timer.periodic(_alignInterval, (_) => _checkAlignment());
      _notify();
    } catch (error) {
      enabled = false;
      listening = false;
      this.error = _describe(error);
      _notify();
    }
  }

  /// 停止智能base：释放输入与低音循环。
  Future<void> disable() async {
    if (_disposed || !enabled) return;
    enabled = false;
    ++_generation;
    _subscription?.cancel();
    _subscription = null;
    _alignTimer?.cancel();
    _alignTimer = null;
    _swapTimer?.cancel();
    _swapTimer = null;
    listening = false;
    playing = false;
    chord = null;
    _candidate = null;
    _candidateHits = 0;
    _received = 0;
    _analysed = 0;
    _writeIndex = 0;
    _pendingPattern = null;
    final audio = _audio;
    _audio = null;
    if (audio != null) {
      try {
        await audio.dispose();
      } catch (_) {
        // 设备已经消失时忽略。
      }
    }
    try {
      await input.stop();
    } catch (_) {
      // 输入已经关闭时忽略。
    }
    _notify();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  /// 收到一段 PCM16 单声道数据。
  void _onBytes(Uint8List bytes) {
    if (_disposed || bytes.isEmpty) return;
    final count = bytes.length ~/ 2;
    for (var i = 0; i < count; i++) {
      var sample = bytes[2 * i] | (bytes[2 * i + 1] << 8);
      if (sample >= 0x8000) sample -= 0x10000;
      _window[_writeIndex] = sample / 32768.0;
      _writeIndex = (_writeIndex + 1) % windowSize;
    }
    _received += count;
    if (_received - _analysed < _hopSize || _received < windowSize) return;
    _analysed = _received;
    _analyse();
  }

  /// 取最近一段样本，按时间顺序排好。
  Float32List _analysisWindow() {
    final out = Float32List(windowSize);
    for (var i = 0; i < windowSize; i++) {
      out[i] = _window[(_writeIndex + i) % windowSize];
    }
    return out;
  }

  void _analyse() {
    final detected = detectChord(
      _analysisWindow(),
      sampleRate: inputSampleRate,
    );
    if (detected == null) {
      _candidate = null;
      _candidateHits = 0;
      return;
    }
    final current = chord;
    if (current != null &&
        current.root == detected.root &&
        current.quality == detected.quality) {
      _candidate = null;
      _candidateHits = 0;
      return;
    }
    if (_candidate != null &&
        _candidate!.root == detected.root &&
        _candidate!.quality == detected.quality) {
      _candidateHits++;
    } else {
      _candidate = detected;
      _candidateHits = 1;
    }
    if (_candidateHits < _stableHits) return;
    _applyChord(detected);
  }

  void _applyChord(ChordDetection detected) {
    chord = detected;
    _candidate = null;
    _candidateHits = 0;
    _queuePattern(detected);
    _notify();
  }

  /// 把和弦编成一小节的低音，并排到下一拍切换。
  void _queuePattern(ChordDetection detected) {
    final bar = _barMicros;
    final beat = _beatMicros;
    final phase = _phaseMicros();
    var offset = 0;
    var delay = 0;
    if (phase != null && beat > 0 && bar > 0) {
      // 量化到下一拍：和弦变化落在拍点上，低音不会切在拍中间。
      final target = ((phase + beat - 1) ~/ beat) * beat;
      offset = target % bar;
      delay = target - phase;
    }
    _pendingOffsetMicros = offset;
    _pendingPattern = _render(detected, landingStep: _stepOf(offset));
    _swapTimer?.cancel();
    _swapTimer = Timer(
      Duration(microseconds: delay),
      () => unawaited(_applyPending()),
    );
  }

  /// 编排一小节的低音；[landingStep] 是切换落点，必要时补一个根音。
  MetronomePattern _render(ChordDetection detected, {int? landingStep}) {
    final notes = buildBassNotes(
      chord: detected,
      style: _style,
      meter: _meter,
      hits: _hits,
      swing: _swing,
    ).toList();
    if (landingStep != null) {
      final landing = _landingNote(detected, notes, landingStep);
      if (landing != null) notes.add(landing);
    }
    return renderBass(bpm: _bpm, notes: notes, meter: _meter, swing: _swing);
  }

  /// 切换落点上如果本来没有音，补一个根音，避免低音出现空档。
  BassNote? _landingNote(
    ChordDetection detected,
    List<BassNote> notes,
    int step,
  ) {
    for (final note in notes) {
      if (note.step == step) return null;
      if (note.step < step && step < note.step + note.lengthSteps) return null;
    }
    return BassNote(midi: bassRootMidi(detected), step: step, lengthSteps: 1);
  }

  /// 把排好的低音切到播放状态。
  Future<void> _applyPending() async {
    if (_disposed) return;
    final pattern = _pendingPattern;
    if (pattern == null) return;
    _pendingPattern = null;
    final audio = _audio;
    if (audio == null) return;
    try {
      await _fadeOut(audio);
      await audio.clear();
      await audio.prepare(pattern);
      audio.setGain(_volume);
      audio.playAt(Duration(microseconds: _pendingOffsetMicros));
      playing = true;
      error = null;
    } catch (error) {
      playing = false;
      this.error = _describe(error);
    }
    _notify();
  }

  /// 切换前把音量快速降到 0，减少硬切的咔哒声。
  Future<void> _fadeOut(PositionedLoopAudio audio) async {
    const steps = 4;
    final start = _volume;
    if (start <= 0) return;
    for (var i = 1; i <= steps; i++) {
      if (_disposed) return;
      try {
        audio.setGain(start * (1 - i / steps));
      } catch (_) {
        return;
      }
      await Future<void>.delayed(_fadeOutLength ~/ steps);
    }
  }

  /// 检查低音与鼓机的相位；偏差过大就重新对齐。
  void _checkAlignment() {
    if (_disposed || !playing) return;
    final drum = drumPosition?.call();
    if (drum == null) return;
    final bar = _barMicros;
    if (bar <= 0) return;
    final audio = _audio;
    if (audio == null) return;
    int bassPhase;
    try {
      bassPhase = audio.position.inMicroseconds % bar;
    } catch (_) {
      return;
    }
    var diff = (drum.inMicroseconds % bar) - bassPhase;
    if (diff > bar ~/ 2) diff -= bar;
    if (diff < -bar ~/ 2) diff += bar;
    if (diff.abs() <= _alignTolerance.inMicroseconds) return;
    // 鼓机重新开始或改过速度：把低音拉回鼓机的相位。
    final current = chord;
    if (current == null) return;
    _queuePattern(current);
  }

  /// 当前落在小节的第几相位（微秒）。
  ///
  /// 优先用鼓机的位置，这样低音和鼓机共享同一条时间线。
  int? _phaseMicros() {
    final bar = _barMicros;
    if (bar <= 0) return null;
    final drum = drumPosition?.call();
    if (drum != null) return drum.inMicroseconds % bar;
    final audio = _audio;
    if (audio == null || !playing) return null;
    try {
      return audio.position.inMicroseconds % bar;
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

  /// 一拍的长度（微秒）。
  int get _beatMicros {
    final bar = _barMicros;
    if (bar <= 0 || _meter.beats <= 0) return 0;
    return bar ~/ _meter.beats;
  }

  /// 小节内相位对应的十六分音符步号。
  int _stepOf(int offsetMicros) {
    final bar = _barMicros;
    if (bar <= 0) return 0;
    return (offsetMicros * _meter.steps) ~/ bar;
  }

  String _describe(Object failure) {
    if (failure is StateError) {
      final message = failure.message.toString();
      if (message.contains('监听')) {
        return '请先在效果器区域开始监听，再开启智能base。';
      }
      return message;
    }
    return '智能base 启动失败，请检查音频输入后重试。';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _subscription?.cancel();
    _subscription = null;
    _alignTimer?.cancel();
    _alignTimer = null;
    _swapTimer?.cancel();
    _swapTimer = null;
    final audio = _audio;
    _audio = null;
    if (audio != null) unawaited(audio.dispose());
    unawaited(input.stop().catchError((Object _) {}));
    super.dispose();
  }
}
