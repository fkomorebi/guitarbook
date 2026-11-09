import '../../app/theme.dart';
import 'package:flutter/material.dart';

import '../band/band_controller.dart';
import '../band/band_panel.dart';
import '../effects/effects_page.dart';
import '../effects/effects_backend.dart';
import '../looper/looper_panel.dart';
import '../looper/effects_loop_input.dart';
import '../looper/looper_controller.dart';
import '../metronome/metronome_audio.dart';
import '../metronome/metronome_audio_factory.dart';
import '../metronome/metronome_controller.dart';
import 'drum_pattern.dart';
import '../looper/loop_audio.dart';
import '../jam_recording/shared_loop_input.dart';
import '../jam_recording/recording_audio.dart';
import '../jam_recording/jam_recorder.dart';
import '../jam_recording/save_recording.dart';
import '../metronome/metronome_pattern.dart';
import '../smart_bass/smart_bass_controller.dart';
import '../smart_bass/smart_bass_panel.dart';
import 'dart:async';
import 'dart:typed_data';

class DrumsPage extends StatefulWidget {
  const DrumsPage({
    super.key,
    this.audio,
    this.looperController,
    this.effectsBackend,
    this.recordingInput,
    this.previewFactory,
  });
  final EffectsBackend? effectsBackend;
  final LooperController? looperController;
  final MetronomeAudio? audio;
  final LoopInput? recordingInput;
  final PositionedLoopAudio Function()? previewFactory;

  @override
  State<DrumsPage> createState() => _DrumsPageState();
}

class _DrumsPageState extends State<DrumsPage> with WidgetsBindingObserver {
  late final MetronomeController _controller;
  late final SmartBassController _smartBass;
  late final BandController _band;
  final _recordingOutputs = <RecordingAudio>{};
  late final SharedLoopInput _sharedInput;
  late final LooperController _looper;
  late final JamRecorder _recorder;
  bool _saving = false;
  String? _savedPath;
  MetronomeAudio? _preview;
  Timer? _previewEnd;
  int _previewGeneration = 0;
  bool _previewing = false;

  void _stopPreview() {
    ++_previewGeneration;
    _previewEnd?.cancel();
    final audio = _preview;
    _preview = null;
    _previewing = false;
    if (audio != null) {
      audio.silence();
      unawaited(audio.dispose());
    }
  }

  Future<void> _playPreview() async {
    _stopPreview();
    final buffer = _recorder.buffer;
    if (buffer == null || buffer.length == 0) return;
    final audio = _preview = widget.previewFactory?.call() ?? createLoopAudio();
    final generation = _previewGeneration;
    setState(() => _previewing = true);
    try {
      await audio.unlock();
      if (!mounted || generation != _previewGeneration) return;
      final samples = Float32List(buffer.length);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = buffer.sampleAt(i) / 32768;
      }
      await audio.prepare(
        MetronomePattern.rendered(
          bpm: 100,
          beats: 4,
          sampleRate: 48000,
          framesPerBeat: buffer.length ~/ 4,
          samples: samples,
        ),
      );
      if (!mounted || generation != _previewGeneration) return;
      audio.play();
      _previewEnd = Timer(
        Duration(microseconds: buffer.length * 1000000 ~/ 48000),
        () {
          _stopPreview();
          if (mounted) setState(() {});
        },
      );
    } catch (_) {
      if (mounted && generation == _previewGeneration) {
        _stopPreview();
        setState(() => _savedPath = '试听失败，录音仍可保存。');
      }
    }
  }

  RecordingAudio _tap(MetronomeAudio audio) {
    final tap = RecordingAudio(audio, _recordingOutputs.remove);
    _recordingOutputs.add(tap);
    return tap;
  }

  late final _effectsBackend = widget.effectsBackend ?? EffectsBackend();
  final _looperKey = GlobalKey();
  final _drumKey = GlobalKey();
  List<List<bool>> _hits = [];
  final _muted = [false, false, false, false, false];
  int _swing = 0;
  bool _capturing = false;
  int _stepPage = 0;
  String _preset = '摇滚';
  DrumMeter _meter = const DrumMeter(4, 4);

  void _load(DrumPreset preset) {
    _preset = preset.name;
    _meter = preset.meter;
    _swing = preset.swing;
    _hits = [
      for (final row in preset.hits)
        List.generate(preset.meter.steps, row.contains),
    ];
    _muted.fillRange(0, drumTrackNames.length, false);
    _stepPage = 0;
  }

  @override
  void initState() {
    super.initState();
    _load(drumPresets.first);
    _sharedInput = SharedLoopInput(
      widget.recordingInput ??
          (_effectsBackend.supported
              ? EffectsLoopInput(_effectsBackend)
              : RecorderLoopInput()),
    );
    _looper =
        widget.looperController ??
        LooperController(_sharedInput.lease(), () => _tap(createLoopAudio()));
    _recorder = JamRecorder(_sharedInput.lease(), _recordingOutputs)
      ..addListener(_refresh);
    _controller = MetronomeController(
      _tap(widget.audio ?? createMetronomeAudio()),
      patternBuilder: (bpm) =>
          renderDrums(bpm, _hits, _muted, _swing, meter: _meter),
    )..addListener(_refresh);
    // 智能base复用工作台的输入通道，不再单独打开麦克风。
    _smartBass = SmartBassController(
      input: _sharedInput.lease(),
      audioFactory: () => _tap(createLoopAudio()),
      drumPosition: () => _controller.position,
    )..addListener(_refresh);
    // 乐队 · 和弦进行只做合成，不需要麦克风，自己占一路循环音频。
    _band = BandController(
      audioFactory: () => _tap(createLoopAudio()),
      drumPosition: () => _controller.position,
    )..addListener(_refresh);
    _syncGroove();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 把鼓机当前的编排同步给智能base和和弦进行，保证三者在同一张网格上。
  void _syncGroove() {
    _smartBass.setGroove(
      bpm: _controller.bpm,
      meter: _meter,
      hits: _hits,
      swing: _swing,
    );
    _band.setGroove(
      bpm: _controller.bpm,
      meter: _meter,
      swing: _swing,
    );
  }

  void _refresh() => setState(() {});
  void _edit(VoidCallback change) {
    change();
    // 拍号决定拍点数量与每拍长度，改动后要让节拍器按新拍号高亮。
    _controller.configure(
      beats: _meter.beats,
      beatDenominator: _meter.denominator,
    );
    // 鼓件的落点变了，智能base要按同一套落点重新编排低音。
    _syncGroove();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _controller.stop();
      _recorder.stop();
      _stopPreview();
      // 后台释放输入，避免一直占着麦克风。
      unawaited(_smartBass.disable());
      unawaited(_band.disable());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_refresh);
    _controller.dispose();
    _recorder.removeListener(_refresh);
    _recorder.dispose();
    _stopPreview();
    _smartBass.removeListener(_refresh);
    // 先释放智能base，它还占着共享输入通道的一路租约。
    _smartBass.dispose();
    _band.removeListener(_refresh);
    _band.dispose();
    if (widget.looperController == null) _looper.dispose();
    _sharedInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final original = Theme.of(context);
    final scheme = original.colorScheme;
    return Theme(
      data: original.copyWith(colorScheme: scheme),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: scheme.surfaceContainerLowest,
          appBar: AppBar(
            backgroundColor: scheme.surfaceContainerLowest,
            title: const Text('即兴工作台'),
            actions: [
              if (_capturing || _recorder.recording || _smartBass.listening)
                Tooltip(
                  message: '音频输入正在使用',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(
                      Icons.mic,
                      color: PracticeColors.recording(context),
                    ),
                  ),
                ),
              IconButton(
                tooltip: '使用说明',
                icon: const Icon(Icons.help_outline),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('开始你的即兴'),
                    content: const SingleChildScrollView(
                      child: Text(
                        '先选一个鼓机律动，点击开始伴奏；再用 Looper 录下吉他并逐层叠录。\n\n'
                        '点击鼓件名称可静音，点击格子编辑十六分音符。修改鼓机参数会从首拍重启。窄屏用分页查看全部鼓点。\n\n'
                        '拍号可选 4/4、3/4、2/4、5/4、6/8、7/8，切换后自动载入该拍号的默认节奏，速度与音量保持不变。x/4 拍号一拍是四分音符，x/8 拍号一拍是八分音符，网格始终按十六分音符划分，摇摆会把每个八分音符的后半拍往后拖。\n\n'
                        '「智能base」会听你弹的和弦，按当前速度、拍号和底鼓落点自动编排一条低音：开启后弹一个和弦，它会在下一拍落下新根音，并一直跟着鼓机循环。风格可在跟底鼓、根音律动、走动低音之间切换，低音音量独立可调。它和 Looper、即兴录音共用同一个输入通道，不会重复打开麦克风。\n\n'
                        '「乐队 · 和弦进行」是乐队的第三层，在鼓机和智能base之上加一层和弦：可选择流行、摇滚、布鲁斯等和弦进行，演奏方式在柱式、律动、琶音、扫弦之间切换，音量独立可调。它只用合成音，不占用麦克风；和弦进行会从鼓机当前的小节位置开始，换和弦或换演奏方式即时生效。\n\n'
                        '录音与鼓机独立循环，不自动对拍。下方效果器会静音检测引擎和声卡，手动开始监听；鼓机音量、Looper 回放音量与效果器输出音量可独立调节。Android / iOS / Linux / Windows 的 Looper 录入效果器处理后的声音，需先开始监听并设为 48 kHz；其他平台录原始输入。请用耳机避免伴奏串入录音。\n\n'
                        '顶部“即兴录音”可录下三路混音，内存满后覆盖最早片段；停止后可试听或保存 WAV。进入后台会停止播放与采集；离开工作台清空未保存录音和设置。声音受系统音量影响，蓝牙可能增加延迟。',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('知道了'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide =
                    constraints.maxWidth >= 1050 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 21;
                final compact =
                    MediaQuery.textScalerOf(context).scale(14) <= 18 &&
                    constraints.maxHeight < 740;
                final landscape =
                    compact &&
                    constraints.maxHeight < 400 &&
                    constraints.maxWidth >= 600;
                final drum = KeyedSubtree(
                  key: _drumKey,
                  child: landscape
                      ? _landscapeDrums(context)
                      : _drumDeck(context, compact: compact),
                );
                final loop = LooperPanel(
                  key: _looperKey,
                  controller: _looper,
                  wetInput: _effectsBackend.supported,
                  compact: compact,
                  landscape: landscape,
                  onCaptureChanged: (capturing) {
                    if (_capturing != capturing) {
                      setState(() => _capturing = capturing);
                    }
                  },
                );
                return SingleChildScrollView(
                  key: const ValueKey('jam-workspace-scroll'),
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1440),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _recordingPanel(context),
                          const SizedBox(height: 16),
                          if (wide)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(width: 324, child: loop),
                                const SizedBox(width: 16),
                                Expanded(child: drum),
                              ],
                            )
                          else ...[
                            drum,
                            const SizedBox(height: 16),
                            loop,
                          ],
                          const SizedBox(height: 16),
                          SmartBassPanel(controller: _smartBass),
                          const SizedBox(height: 16),
                          BandPanel(controller: _band),
                          const SizedBox(height: 16),
                          EffectsPage(
                            key: const ValueKey('jam-effects'),
                            embedded: true,
                            backend: _effectsBackend,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _recordingPanel(BuildContext context) {
    final r = _recorder;
    final active = r.recording || r.starting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('即兴录音', style: Theme.of(context).textTheme.titleLarge),
            const Text('录下鼓机、Looper 与演奏。容量用满后覆盖最早片段。新录音会替换未保存的片段。'),
            Text(
              '录音内存 · 最长约 ${(r.memoryMiB * 1024 * 1024 / 96000 / 60).toStringAsFixed(1)} 分钟',
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 180,
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: r.memoryMiB,
                    items: [
                      for (final size in [8, 16, 32, 64, 128])
                        DropdownMenuItem(
                          value: size,
                          child: Text(
                            '$size MiB',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: active || _saving
                        ? null
                        : (size) => setState(() => r.memoryMiB = size!),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _saving
                      ? null
                      : active
                      ? r.stop
                      : () {
                          _stopPreview();
                          _savedPath = null;
                          r.start();
                        },
                  icon: Icon(active ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(
                    r.starting
                        ? '取消准备'
                        : r.recording
                        ? '停止录音'
                        : '开始录音',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: active || _saving || (r.buffer?.length ?? 0) == 0
                      ? null
                      : () {
                          if (_previewing) {
                            setState(_stopPreview);
                          } else {
                            _playPreview();
                          }
                        },
                  icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                  label: Text(_previewing ? '停止试听' : '试听录音'),
                ),
                OutlinedButton.icon(
                  onPressed: active || _saving || (r.buffer?.length ?? 0) == 0
                      ? null
                      : () async {
                          setState(() => _saving = true);
                          try {
                            final path = await saveRecording(r.buffer!.toWav());
                            if (mounted) setState(() => _savedPath = path);
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _savedPath = '保存失败，请检查存储空间后重试；录音仍在内存中。',
                              );
                            }
                          } finally {
                            if (mounted) setState(() => _saving = false);
                          }
                        },
                  icon: const Icon(Icons.save_alt),
                  label: Text(_saving ? '保存中…' : '保存'),
                ),
              ],
            ),
            Text(
              '已保留 ${((r.buffer?.length ?? 0) / 48000).toStringAsFixed(1)} 秒${(r.buffer?.totalFrames ?? 0) > (r.buffer?.length ?? 0) ? ' · 正在保留最近片段' : ''}',
            ),
            if (r.error != null)
              Text(
                r.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_savedPath != null) SelectableText(_savedPath!),
            const Text('支持效果器的平台需先开始监听（48 kHz）；演奏录入效果链后的声音，不受监听音量影响。请用耳机避免串音。'),
          ],
        ),
      ),
    );
  }

  Widget _drumVolume() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('鼓机音量 ${(_controller.volume * 100).round()}%'),
      Slider(
        key: const ValueKey('drum-volume'),
        value: _controller.volume,
        divisions: 100,
        label: '${(_controller.volume * 100).round()}%',
        semanticFormatterCallback: (value) => '鼓机音量 ${(value * 100).round()}%',
        onChanged: _controller.setVolume,
      ),
    ],
  );

  /// 拍号选择：切换后载入该拍号的默认预设，速度与音量保持不变。
  Widget _meterChips() => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      for (final meter in drumMeters)
        ChoiceChip(
          key: ValueKey('drum-meter-${meter.label}'),
          label: Text(meter.label),
          selected: _meter == meter,
          showCheckmark: false,
          onSelected: (selected) {
            // 再点一次当前拍号不改内容，避免丢掉用户已经编辑的节奏。
            if (!selected || _meter == meter) return;
            _edit(() => _load(drumDefaultPreset(meter)));
          },
        ),
    ],
  );

  /// 拍点指示条，段数与当前拍号的拍数一致。
  Widget _beatBar(BuildContext context) {
    final c = _controller;
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var beat = 1; beat <= _meter.beats; beat++)
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 5,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: c.running && !c.preparing && c.beat == beat
                    ? colors.primary
                    : colors.surfaceContainerHighest,
              ),
            ),
          ),
      ],
    );
  }

  Widget _drumDeck(BuildContext context, {bool compact = false}) {
    final c = _controller;
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('drum-deck'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.outlineVariant),
      ),
      padding: EdgeInsets.all(compact ? 12 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.graphic_eq, color: colors.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!compact)
                      Text(
                        'DRUM MACHINE',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          letterSpacing: 2,
                          color: colors.primary,
                        ),
                      ),
                    Text(
                      '律动编排',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _meter.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 16),
          _meterChips(),
          SizedBox(height: compact ? 6 : 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final preset in drumPresetsFor(_meter))
                ChoiceChip(
                  label: Text(preset.name),
                  selected: _preset == preset.name,
                  showCheckmark: false,
                  onSelected: (_) => _edit(() => _load(preset)),
                ),
              if (_preset == '自定义') const Chip(label: Text('自定义')),
            ],
          ),
          SizedBox(height: compact ? 6 : 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final tempo = _tempo(context);
              final swing = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '摇摆 $_swing%',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Slider(
                    value: _swing.toDouble(),
                    min: 0,
                    max: 60,
                    divisions: 60,
                    label: '$_swing%',
                    onChanged: (v) => _edit(() {
                      _swing = v.round();
                      _preset = '自定义';
                    }),
                  ),
                ],
              );
              if (constraints.maxWidth >= 500) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 3, child: tempo),
                    const SizedBox(width: 24),
                    Expanded(flex: 2, child: swing),
                  ],
                );
              }
              return Column(children: [tempo, swing]);
            },
          ),
          SizedBox(height: compact ? 4 : 8),
          _drumVolume(),
          _grid(context, compact: compact),
          SizedBox(height: compact ? 6 : 16),
          _beatBar(context),
          SizedBox(height: compact ? 6 : 12),
          Text(
            c.preparing
                ? '正在准备声音…'
                : c.running
                ? '第 ${c.beat} / ${_meter.beats} 拍'
                : '$_preset · 准备就绪',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '鼓音播放失败，请检查音频设备后点击开始重试。',
                style: TextStyle(color: colors.error),
              ),
            ),
          SizedBox(height: compact ? 6 : 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: c.running ? c.stop : c.start,
            icon: Icon(
              c.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
            ),
            label: Text(c.running ? '停止伴奏' : '开始伴奏'),
          ),
          if (!compact) const SizedBox(height: 10),
          if (!compact)
            Text(
              '点格子编排 · 点鼓件静音 · 修改后从首拍重启',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _landscapeDrums(BuildContext context) {
    final c = _controller;
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('drum-deck'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                value: _preset,
                underline: const SizedBox(),
                items: [
                  for (final preset in drumPresetsFor(_meter))
                    DropdownMenuItem(
                      value: preset.name,
                      child: Text(preset.name),
                    ),
                  if (_preset == '自定义')
                    const DropdownMenuItem(value: '自定义', child: Text('自定义')),
                ],
                onChanged: (name) {
                  for (final preset in drumPresetsFor(_meter)) {
                    if (preset.name == name) _edit(() => _load(preset));
                  }
                },
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '减慢 1 BPM',
                    onPressed: c.bpm > 30
                        ? () => c.configure(bpm: c.bpm - 1)
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text(
                    '${c.bpm} BPM',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  IconButton(
                    tooltip: '加快 1 BPM',
                    onPressed: c.bpm < 240
                        ? () => c.configure(bpm: c.bpm + 1)
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              TextButton(
                onPressed: () => _showSwing(context),
                child: Text('摇摆 $_swing%'),
              ),
              FilledButton.icon(
                onPressed: c.running ? c.stop : c.start,
                icon: Icon(
                  c.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                ),
                label: Text(c.running ? '停止伴奏' : '开始伴奏'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _meterChips(),
          const SizedBox(height: 6),
          _drumVolume(),
          _grid(context, compact: true),
          const SizedBox(height: 6),
          _beatBar(context),
          const SizedBox(height: 6),
          Text(
            c.preparing
                ? '正在准备声音…'
                : c.running
                ? '第 ${c.beat} / ${_meter.beats} 拍'
                : '$_preset · 准备就绪',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          if (c.error != null)
            Text('鼓音播放失败，请检查音频设备后重试。', style: TextStyle(color: colors.error)),
        ],
      ),
    );
  }

  Future<void> _showSwing(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: Text('摇摆 $_swing%'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('0 为均分，33 为近似三连音。修改会从首拍重启鼓机。'),
              Slider(
                value: _swing.toDouble(),
                min: 0,
                max: 60,
                divisions: 60,
                onChanged: (v) {
                  _edit(() {
                    _swing = v.round();
                    _preset = '自定义';
                  });
                  refresh(() {});
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );

  Widget _tempo(BuildContext context) {
    final c = _controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${c.bpm}',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: '  BPM'),
            ],
          ),
        ),
        Row(
          children: [
            IconButton(
              tooltip: '减慢 1 BPM',
              visualDensity: VisualDensity.compact,
              onPressed: c.bpm > 30 ? () => _setBpm(c.bpm - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Slider(
                value: c.bpm.toDouble(),
                min: 30,
                max: 240,
                divisions: 210,
                label: '${c.bpm} BPM',
                onChanged: (v) => _setBpm(v.round()),
              ),
            ),
            IconButton(
              tooltip: '加快 1 BPM',
              visualDensity: VisualDensity.compact,
              onPressed: c.bpm < 240 ? () => _setBpm(c.bpm + 1) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  /// 改速度：鼓机与智能base都要按新速度重新编排。
  void _setBpm(int bpm) {
    _controller.configure(bpm: bpm);
    _syncGroove();
  }

  Widget _grid(BuildContext context, {bool compact = false}) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final scaled = MediaQuery.textScalerOf(context).scale(14);
      final meter = _meter;
      final stepsPerBeat = meter.stepsPerBeat;
      // 每一页按整拍切分，翻页时不会把一拍拆到两页。
      final beatsPerPage = constraints.maxWidth >= 650
          ? 4
          : constraints.maxWidth >= 410
          ? 2
          : stepsPerBeat == 2
          ? 2
          : 1;
      final pageBeats = beatsPerPage < meter.beats ? beatsPerPage : meter.beats;
      final count = pageBeats * stepsPerBeat;
      final pages = (meter.steps + count - 1) ~/ count;
      final page = _stepPage.clamp(0, pages - 1);
      final start = page * count;
      // 末页可能不满一页，列数对齐到实际步数即可。
      final end = start + count > meter.steps ? meter.steps : start + count;
      final labelWidth = scaled > 21 ? 80.0 : 64.0;
      final palette = [
        const Color(0xFFCC8749),
        const Color(0xFF4B9E96),
        const Color(0xFF8A83BF),
        const Color(0xFFC0636F),
        const Color(0xFF6F9BC0),
      ];
      final cellHeight = scaled > 21
          ? 56.0
          : compact
          ? 36.0
          : 42.0;
      return Column(
        children: [
          if (pages > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text('拍', style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(width: 8),
                  for (var i = 0; i < pages; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          key: ValueKey('drum-page-$i'),
                          label: Text(_pageLabel(i, pageBeats)),
                          selected: page == i,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => _stepPage = i),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              SizedBox(width: labelWidth),
              for (var i = start; i < end; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      _stepLabel(i),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: i % stepsPerBeat == 0
                            ? FontWeight.w800
                            : FontWeight.normal,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (var track = 0; track < drumTrackNames.length; track++)
            Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Tooltip(
                    message: _muted[track] ? '取消静音' : '静音',
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: _muted[track]
                            ? colors.outline
                            : colors.onSurface,
                      ),
                      onPressed: () =>
                          _edit(() => _muted[track] = !_muted[track]),
                      child: Text(
                        drumTrackNames[track],
                        style: TextStyle(
                          decoration: _muted[track]
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                for (var step = start; step < end; step++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        step % stepsPerBeat == 0 ? 4 : 2,
                        3,
                        2,
                        3,
                      ),
                      child: Semantics(
                        button: true,
                        label: '${drumTrackNames[track]} 第 ${step + 1} 步',
                        toggled: _hits[track][step],
                        child: Tooltip(
                          message: '第 ${step + 1} 步',
                          child: SizedBox(
                            height: cellHeight,
                            child: Material(
                              color: _hits[track][step]
                                  ? (_muted[track]
                                        ? colors.surfaceContainerHighest
                                        : palette[track])
                                  : colors.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(
                                  color:
                                      _controller.running &&
                                          !_controller.preparing &&
                                          _controller.beat ==
                                              step ~/ stepsPerBeat + 1
                                      ? colors.primary
                                      : colors.outlineVariant,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _edit(() {
                                  _hits[track][step] = !_hits[track][step];
                                  _preset = '自定义';
                                }),
                                child: Center(
                                  child: Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _hits[track][step]
                                          ? Colors.white
                                          : colors.outlineVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );

  /// 页签文案用拍号区间标记当前页覆盖哪几拍。
  String _pageLabel(int index, int pageBeats) {
    final first = index * pageBeats + 1;
    final last = (index + 1) * pageBeats > _meter.beats
        ? _meter.beats
        : (index + 1) * pageBeats;
    return first == last ? '$first' : '$first–$last';
  }

  /// 步进标签：四分音符拍号用 1 / e / & / a，八分音符拍号用拍号数字与 e。
  String _stepLabel(int step) {
    final stepsPerBeat = _meter.stepsPerBeat;
    if (stepsPerBeat == 2) {
      return step % 2 == 0 ? '${step ~/ 2 + 1}' : 'e';
    }
    return step % 4 == 0 ? '${step ~/ 4 + 1}' : ['e', '&', 'a'][step % 4 - 1];
  }
}
