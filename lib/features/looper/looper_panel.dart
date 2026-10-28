import '../../app/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'loop_audio.dart';
import 'effects_loop_input.dart';
import 'looper_controller.dart';
import 'pedal_bindings.dart';

class LooperPanel extends StatefulWidget {
  const LooperPanel({
    super.key,
    this.controller,
    this.input,
    this.onCaptureChanged,
    this.onActivityChanged,
    this.compact = false,
    this.landscape = false,
  });
  final bool compact;
  final bool landscape;
  final ValueChanged<String>? onActivityChanged;
  final ValueChanged<bool>? onCaptureChanged;
  final LooperController? controller;
  final LoopInput? input;

  @override
  State<LooperPanel> createState() => _LooperPanelState();
}

class _LooperPanelState extends State<LooperPanel> with WidgetsBindingObserver {
  late final LooperController _c;
  final _bindings = PedalBindings();
  bool _foreground = true;
  bool _settingsOpen = false;
  StateSetter? _settingsRefresh;

  @override
  void initState() {
    super.initState();
    _c =
        widget.controller ??
        LooperController(widget.input ?? RecorderLoopInput(), createLoopAudio);
    _c.addListener(_refresh);
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_earlyKey);
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
      widget.onCaptureChanged?.call(_c.capturing);
      widget.onActivityChanged?.call(
        _c.recording
            ? (_c.smartWaiting ? '等待琴声' : '录音中')
            : _c.playing
            ? '循环中'
            : '',
      );
      _settingsRefresh?.call(() {});
    }
  }

  void _trigger(PedalAction action) {
    if (!_foreground || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    switch (action) {
      case PedalAction.main:
        _c.mainPedal();
      case PedalAction.stop:
        _c.togglePlayback();
      case PedalAction.undo:
        _c.undo();
      case PedalAction.clear:
        _c.clear();
    }
  }

  KeyEventResult _earlyKey(KeyEvent event) =>
      _key(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  bool _key(KeyEvent event) {
    if (!_foreground) return false;
    if (_settingsOpen) {
      if (_bindings.learning == null) return false;
    } else if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    // Rebinding is explicit; otherwise leave text editing and control shortcuts alone.
    if (_bindings.learning == null &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed ||
            FocusManager.instance.primaryFocus?.context?.widget
                is EditableText ||
            FocusManager.instance.primaryFocus?.context
                    ?.findAncestorWidgetOfExactType<EditableText>() !=
                null)) {
      return false;
    }
    final handled = _bindings.key(event, _trigger);
    if (handled) _refresh();
    return handled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _bindings.learning = null;
      _c.stop();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_earlyKey);
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_refresh);
    if (widget.controller == null) _c.dispose();
    super.dispose();
  }

  String get _status => _c.busy
      ? '正在准备音频…'
      : _c.smartWaiting
      ? (_c.smartCalibrating ? '检测底噪 · 请安静半秒' : '等待琴声 · 弹奏后自动录音')
      : _c.recording
      ? '${_c.layers == 0 ? '首层录音' : '叠录中'} · ${_c.recordedSeconds.toStringAsFixed(1)} 秒'
      : _c.playing
      ? '循环播放中'
      : _c.layers == 0
      ? '等待第一层录音'
      : '已停止 · 保留录音';

  String _keyLabel(PedalAction action) {
    final key = _bindings.keys[action];
    return key == LogicalKeyboardKey.space ? 'SPACE' : key?.keyLabel ?? '未绑定';
  }

  void _updateSettings(VoidCallback change) {
    setState(change);
    _settingsRefresh?.call(() {});
  }

  Future<void> _showSettings() async {
    _settingsOpen = true;
    if (!_c.capturing && !_c.busy) _c.refreshDevices();
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) {
            _settingsRefresh = refresh;
            return AlertDialog(
              title: const Text('踏板绑定与录音设置'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _settings(context),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      _settingsRefresh = null;
      _settingsOpen = false;
      _bindings.learning = null;
      if (mounted) setState(() {});
    }
  }

  double get _progress {
    if (_c.recording && _c.layers == 0) {
      return (_c.recordedSeconds / 30).clamp(0, 1);
    }
    if (!_c.playing || _c.frames == 0) return 0;
    try {
      return (_c.position.inMicroseconds / 1000000 / _c.seconds) % 1;
    } catch (_) {
      return 0;
    }
  }

  String get _mainLabel => _c.smartWaiting
      ? '取消等待'
      : _c.recording
      ? '结束录音并循环'
      : _c.playing
      ? '开始叠录'
      : _c.layers > 0
      ? '恢复循环'
      : _c.smartEnabled
      ? '智能录制第一层'
      : '录制第一层';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compact = widget.compact;
    final active = _c.recording
        ? PracticeColors.recording(context)
        : colors.primary;
    final title = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!compact)
                Text(
                  'LOOP STATION',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 2,
                    color: colors.primary,
                  ),
                ),
              Text(
                'Looper 叠录',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '踏板绑定与录音设置',
          onPressed: _showSettings,
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    );
    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _status,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            color: active,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${_c.layers} / 6 层 · 循环 ${_c.seconds.toStringAsFixed(1)} 秒',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
    final layers = Row(
      children: [
        for (var layer = 0; layer < 6; layer++)
          Expanded(
            child: Semantics(
              label: '第 ${layer + 1} 层${layer < _c.layers ? '已录制' : '空'}',
              child: Container(
                height: 26,
                alignment: Alignment.center,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: layer < _c.layers
                      ? colors.primaryContainer
                      : colors.surfaceContainerLow,
                ),
                child: Text(
                  '${layer + 1}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: layer < _c.layers
                        ? colors.onPrimaryContainer
                        : colors.outline,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final controls = Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed:
                _c.playing ||
                    _c.recording ||
                    _c.busy ||
                    _c.capturing ||
                    _c.layers > 0
                ? () => _trigger(PedalAction.stop)
                : null,
            icon: Icon(
              _c.playing || _c.recording || _c.busy || _c.capturing
                  ? Icons.stop_rounded
                  : Icons.play_arrow_rounded,
              size: 18,
            ),
            label: Text(
              _c.playing || _c.recording || _c.busy || _c.capturing
                  ? '停止循环'
                  : '恢复循环',
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '撤销最近一层',
          onPressed: _c.busy || _c.recording || _c.layers == 0
              ? null
              : () => _trigger(PedalAction.undo),
          icon: const Icon(Icons.undo_rounded, size: 20),
        ),
        IconButton(
          tooltip: '清空录音',
          onPressed: () => _trigger(PedalAction.clear),
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
        ),
      ],
    );
    final mouse = Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse) {
          _bindings.pointer(event.buttons, _trigger);
        }
      },
      child: Container(
        key: const ValueKey('loop-mouse-pad'),
        padding: EdgeInsets.all(compact ? 8 : 12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              _c.capturing
                  ? (_c.inputMeter.quiet
                        ? '输入无明显信号 · 请检查录音设置'
                        : '● 输入 ${_c.inputMeter.db.toStringAsFixed(0)} dBFS')
                  : '鼠标踏板区',
              style: theme.textTheme.labelMedium?.copyWith(
                color: _c.capturing ? active : colors.onSurfaceVariant,
              ),
            ),
            if (!widget.landscape) ...[
              const SizedBox(height: 3),
              Text(
                '${_keyLabel(PedalAction.stop)} 停止  ·  ${_keyLabel(PedalAction.undo)} 撤销  ·  ${_keyLabel(PedalAction.clear)} 清空',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final pedal = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: compact ? 100 : 136,
          height: compact ? 100 : 136,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: _c.busy ? null : _progress,
                  strokeWidth: 4,
                  color: active,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
              ),
              SizedBox(
                width: compact ? 82 : 114,
                height: compact ? 82 : 114,
                child: Tooltip(
                  message: _mainLabel,
                  child: Semantics(
                    label: _mainLabel,
                    child: FilledButton(
                      key: const ValueKey('loop-main'),
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                        backgroundColor: active,
                        foregroundColor: _c.recording
                            ? (theme.brightness == Brightness.dark
                                  ? const Color(0xFF3B160B)
                                  : Colors.white)
                            : colors.onPrimary,
                        elevation: 0,
                      ),
                      onPressed: _c.busy
                          ? null
                          : () => _trigger(PedalAction.main),
                      child: Icon(
                        _c.recording
                            ? Icons.check_rounded
                            : _c.playing
                            ? Icons.add_rounded
                            : _c.layers > 0
                            ? Icons.play_arrow_rounded
                            : Icons.fiber_manual_record,
                        size: compact ? 32 : 42,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: compact ? 8 : 12),
        Text(
          _mainLabel,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${_keyLabel(PedalAction.main)}  ·  主踏板',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
    final volume = Row(
      children: [
        const Icon(Icons.volume_up_rounded, size: 18),
        const SizedBox(width: 8),
        Text('回放音量', style: theme.textTheme.labelMedium),
        Expanded(
          child: Slider(
            key: const ValueKey('loop-volume'),
            value: _c.playbackGain,
            min: 0,
            max: 4,
            divisions: 40,
            label: '${(_c.playbackGain * 100).round()}%',
            semanticFormatterCallback: (v) => '回放音量 ${(v * 100).round()}%',
            onChanged: _c.setPlaybackGain,
          ),
        ),
        Text(
          '${(_c.playbackGain * 100).round()}%',
          style: theme.textTheme.labelMedium,
        ),
      ],
    );
    return Container(
      key: const ValueKey('looper-deck'),
      padding: EdgeInsets.all(compact ? 12 : 20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('智能录音'),
              subtitle: Text(
                _c.smartEnabled ? '首层自动起录 · 停奏 2 秒后裁剪并循环' : '无需踩钉，自动裁剪首尾空白',
              ),
              value: _c.smartEnabled,
              onChanged: _c.capturing || _c.busy || _c.layers > 0
                  ? null
                  : _c.setSmartEnabled,
            ),
          ),
          if (widget.landscape)
            Row(
              children: [
                SizedBox(width: 230, child: Column(children: [pedal, volume])),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      status,
                      const SizedBox(height: 10),
                      layers,
                      const SizedBox(height: 8),
                      controls,
                      const SizedBox(height: 6),
                      mouse,
                    ],
                  ),
                ),
              ],
            )
          else ...[
            SizedBox(height: compact ? 8 : 16),
            status,
            SizedBox(height: compact ? 10 : 18),
            Center(child: pedal),
            SizedBox(height: compact ? 10 : 16),
            layers,
            SizedBox(height: compact ? 8 : 16),
            controls,
            SizedBox(height: compact ? 6 : 10),
            mouse,
          ],
          if (!widget.landscape) volume,
          if (_c.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_c.error!, style: TextStyle(color: colors.error)),
            ),
          if (!compact) ...[
            const SizedBox(height: 8),
            Text(
              '戴上耳机 · 首层最长 30 秒 · 离开页面清空',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _settings(BuildContext context) => [
    const Text(
      '点击“绑定键盘”后按一个键，Esc 取消。仅当前页面且窗口有焦点时生效；长按不会重复触发。模拟键盘的 USB 脚踏可使用相同绑定。',
    ),
    for (final action in PedalAction.values)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(action.label),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      _updateSettings(() => _bindings.learning = action),
                  child: Text(
                    _bindings.learning == action
                        ? '请按键…（Esc 取消）'
                        : '绑定键盘：${_keyLabel(action)}',
                  ),
                ),
                DropdownButton<int>(
                  value: _bindings.mouse[action] ?? 0,
                  items: [
                    const DropdownMenuItem(value: 0, child: Text('鼠标未绑定')),
                    for (final entry in pedalMouseButtons.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (v) => _updateSettings(
                    () => _bindings.bindMouse(action, v == 0 ? null : v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    const SizedBox(height: 12),
    if (_c.input is EffectsLoopInput)
      const Text(
        '录音源：效果器处理后的声音（单声道）。先在下方开始监听；输入通道与 48 kHz 采样率在效果器声卡设置中选择。效果器输出音量不影响录音，已录层保留原音色。',
      )
    else ...[
      TextButton.icon(
        onPressed: _c.capturing || _c.busy ? null : _c.refreshDevices,
        icon: const Icon(Icons.refresh),
        label: const Text('刷新录音设备'),
      ),
      DropdownButtonFormField<String>(
        key: ValueKey(
          'device-${_c.device?.id}-${_c.devices.map((d) => d.id).join(',')}',
        ),
        initialValue: _c.device?.id ?? '',
        isExpanded: true,
        decoration: const InputDecoration(labelText: '录音输入'),
        items: [
          const DropdownMenuItem(value: '', child: Text('系统默认输入')),
          for (final device in _c.devices)
            DropdownMenuItem(
              value: device.id,
              child: Text(device.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _c.capturing || _c.busy
            ? null
            : (id) {
                _updateSettings(() {
                  _c.device = id == ''
                      ? null
                      : _c.devices.firstWhere((d) => d.id == id);
                });
              },
      ),
      const SizedBox(height: 8),
      const Text(
        '声卡直通监听有声不代表应用收到信号。请选择吉他连接的 Inst/Line 输入；Mic 是麦克风，Monitor/Loopback 是回环。切换设备前先停止循环。录音时主面板显示输入电平，持续低电平会提示检查。',
      ),
      const SizedBox(height: 12),
    ],
    Text('智能录音触发门槛：${_c.smartThresholdDb.round()} dBFS'),
    Slider(
      key: const ValueKey('smart-threshold'),
      value: _c.smartThresholdDb,
      min: -60,
      max: -20,
      divisions: 40,
      label: '${_c.smartThresholdDb.round()} dBFS',
      onChanged: _c.capturing || _c.busy ? null : _c.setSmartThreshold,
    ),
    const Text(
      '轻弹不触发可调低门槛，杂音误触发可调高。开始后请安静半秒；停奏 2 秒自动结束，段内停顿保留。仅首层生效，不自动对齐鼓机。不能分离人声或外放伴奏，请戴耳机或使用声卡直录。',
    ),
    const SizedBox(height: 12),
    Text('输入延迟补偿：${_c.compensationMs} ms'),
    Slider(
      value: _c.compensationMs.toDouble(),
      min: 0,
      max: 250,
      divisions: 50,
      onChanged: _c.recording || _c.busy
          ? null
          : (v) => _updateSettings(() => _c.compensationMs = v.round()),
    ),
    const Text(
      '补偿仅影响后续叠录的对齐。录音和鼓机不自动对拍、变速或量化；实际延迟和长期同步需设备验证。MIDI、手柄和后台全局快捷键暂未接入。',
    ),
    const SizedBox(height: 12),
    const Text('回放音量 0–400%，100% 为原回放电平。调高会同时放大底噪，多层叠加失真时请调低；不改变录音输入或鼓机音量。'),
    const SizedBox(height: 8),
    const Text(
      '首层：踩一次录音，再踩一次循环。播放中踩一次叠录，再踩一次结束，或满一圈自动结束；最多 6 层。停止丢弃未完成录音，保留已完成层。',
    ),
    const SizedBox(height: 8),
    Text(
      _c.input is EffectsLoopInput
          ? '播放期间保持湿声采集，非录音时丢弃输入。停止 Looper 不停止效果器监听；停止监听会中止录音。混响与延迟尾音按实际录制时长保留，智能录音可能因长尾延后结束。音频仅保存在当前页面内存中。'
          : '播放期间保持采集，为叠录做准备；非录音时丢弃输入。停止后关闭麦克风。无实时软件监听，请使用耳机或声卡直通监听。音频和绑定只保存在当前页面，不写文件、不上传。',
    ),
  ];
}
