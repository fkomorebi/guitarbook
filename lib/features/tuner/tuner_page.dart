import '../../app/theme.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'automatic_string_selector.dart';
import 'pitch_detector.dart';
import 'tuning_feedback.dart';

class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _subscription;
  final _bytes = <int>[];
  bool _running = false;
  bool _busy = false;
  bool _foreground = true;
  int _generation = 0;
  int _selected = 0;
  bool _automatic = true;
  final _selector = AutomaticStringSelector();
  final _feedback = TuningFeedback();
  final _clock = Stopwatch()..start();
  Timer? _expiryTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _expiryTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_running || _feedback.cents == null) return;
      setState(() => _feedback.expire(_clock.elapsedMilliseconds));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_stop());
  }

  Future<void> _start() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('需要麦克风权限，请在系统或浏览器设置中允许后重试。');
      }
      if (!mounted || !_foreground || generation != _generation) return;
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 22050,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );
      if (!mounted || !_foreground || generation != _generation) {
        await _recorder.stop();
        return;
      }
      _subscription = stream.listen(
        _onAudio,
        onError: (Object error) {
          unawaited(_stop(message: '音频采集中断，请检查麦克风后重试。'));
        },
        onDone: () {
          if (_running) unawaited(_stop(message: '音频采集已结束，请重新开始。'));
        },
      );
      setState(() => _running = true);
    } catch (error) {
      await _recorder.stop().catchError((_) => null);
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is StateError
              ? error.message.toString()
              : '无法启动麦克风，请检查权限、设备和平台运行条件后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onAudio(Uint8List chunk) {
    if (!_running || !mounted) return;
    _bytes.addAll(chunk);
    const byteCount = 4096 * 2;
    if (_bytes.length < byteCount) return;
    final data = ByteData.sublistView(
      Uint8List.fromList(_bytes.sublist(_bytes.length - byteCount)),
    );
    // Keep half the window for a new estimate about every 93 ms.
    _bytes.removeRange(0, _bytes.length - byteCount + 4096);
    final samples = List<double>.generate(
      4096,
      (i) => data.getInt16(i * 2, Endian.little) / 32768,
    );
    final frequency = detectPitch(samples);
    setState(() {
      final now = _clock.elapsedMilliseconds;
      if (_automatic) {
        final selected = _selector.update(frequency, now);
        if (selected == null) {
          _feedback.update(null, guitarStrings[_selected].frequency, now);
          // Keep the last reading while a new candidate is being confirmed.
          if (frequency != null) _feedback.interruptConfirmation();
          return;
        }
        if (selected != _selected) {
          _selected = selected;
          _feedback.reset();
        }
      }
      _feedback.update(frequency, guitarStrings[_selected].frequency, now);
    });
  }

  Future<void> _stop({String? message}) async {
    ++_generation;
    final subscription = _subscription;
    _subscription = null;
    if (mounted) {
      setState(() {
        _running = false;
        _selector.reset();
        _feedback.reset();
        _error = message;
      });
    }
    await subscription?.cancel();
    await _recorder.stop().catchError((_) => null);
    _bytes.clear();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    unawaited(_subscription?.cancel());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = guitarStrings[_selected];
    final cents = _feedback.cents;
    final frequency = _feedback.frequency(target.frequency);
    final status = cents == null
        ? (_running
              ? (_automatic ? '请拨响任意一根空弦 · 正在识别' : '请拨响所选空弦')
              : '准备好后开始调音')
        : _feedback.stale
        ? '上次读数 · 请重新拨弦'
        : _feedback.inTune
        ? '已调准'
        : cents.abs() <= 5
        ? '接近准音 · 请保持'
        : cents < 0
        ? '偏低 · 请缓慢拧紧'
        : '偏高 · 请缓慢放松';
    return Scaffold(
      appBar: AppBar(title: const Text('吉他调音器')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('标准调弦 · A4 = 440 Hz'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动识别琴弦'),
                    subtitle: const Text('拨响任意一根空弦；点击琴弦可手动选择'),
                    value: _automatic,
                    onChanged: (value) => setState(() {
                      _automatic = value;
                      _selector.reset();
                      _feedback.reset();
                      _bytes.clear();
                    }),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < guitarStrings.length; i++)
                        ChoiceChip(
                          label: Text(guitarStrings[i].label),
                          selected: i == _selected,
                          onSelected: (_) => setState(() {
                            _automatic = false;
                            _selected = i;
                            _selector.reset();
                            _feedback.reset();
                            _bytes.clear();
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Card.filled(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Text(
                            target.label,
                            style: Theme.of(context).textTheme.headlineLarge,
                          ),
                          Text('目标 ${target.frequency.toStringAsFixed(2)} Hz'),
                          const SizedBox(height: 24),
                          Text(
                            frequency == null
                                ? '— Hz'
                                : '${frequency.toStringAsFixed(1)} Hz',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            cents == null
                                ? '— 音分'
                                : '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(1)} 音分',
                          ),
                          const SizedBox(height: 12),
                          _PitchGauge(cents: cents, inTune: _feedback.inTune),
                          const SizedBox(height: 16),
                          Icon(
                            _feedback.inTune
                                ? Icons.check_circle
                                : Icons.music_note,
                            color: _feedback.inTune
                                ? PracticeColors.inTune(context)
                                : null,
                            size: 32,
                          ),
                          Text(
                            status,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _running ? _stop() : _start(),
                    icon: Icon(_running ? Icons.stop : Icons.mic),
                    label: Text(
                      _busy
                          ? '正在启动…'
                          : _running
                          ? '停止调音'
                          : '开始调音',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '请在安静环境中一次拨响一根空弦。读数稳定后缓慢调整，指针进入中央 ±5 音分区域并保持约 0.6 秒，出现勾号和“已调准”即完成。音频仅在本机分析，不保存或上传。',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PitchGauge extends StatelessWidget {
  const _PitchGauge({required this.cents, required this.inTune});

  final double? cents;
  final bool inTune;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: cents == null ? '等待拨弦' : '音高偏差，中央正负5音分为准音区',
      child: Column(
        children: [
          const Text('准音区 ±5'),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(height: 4, color: colors.outlineVariant),
                    Container(
                      width: width * .1,
                      height: 32,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    Container(width: 2, height: 32, color: colors.primary),
                    if (cents != null)
                      AnimatedAlign(
                        duration: const Duration(milliseconds: 110),
                        curve: Curves.easeOut,
                        alignment: Alignment(cents!.clamp(-50, 50) / 50, 0),
                        child: Icon(
                          Icons.arrow_drop_down,
                          size: 36,
                          color: inTune
                              ? PracticeColors.inTune(context)
                              : colors.primary,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text('偏低 −50')),
              Expanded(child: Text('0', textAlign: TextAlign.center)),
              Expanded(child: Text('偏高 +50', textAlign: TextAlign.right)),
            ],
          ),
        ],
      ),
    );
  }
}
