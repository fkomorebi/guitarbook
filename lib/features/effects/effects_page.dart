import 'dart:async';

import 'package:flutter/material.dart';

import 'effects_backend.dart';

class EffectsPage extends StatefulWidget {
  const EffectsPage({super.key, this.backend});

  final EffectsBackend? backend;

  @override
  State<EffectsPage> createState() => _EffectsPageState();
}

class _EffectsPageState extends State<EffectsPage> with WidgetsBindingObserver {
  late final _backend = widget.backend ?? EffectsBackend();
  final _path = TextEditingController();
  Map<String, dynamic> _status = {};
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  bool _adjustingGain = false;
  bool _adjustingParameter = false;
  Timer? _parameterTimer;
  Map<String, dynamic>? _pendingParameter;
  bool _connected = false;
  String? _error;

  bool get _running => _status['running'] == true;
  List<dynamic> get _plugins => _status['plugins'] as List<dynamic>? ?? [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _poll());
  }

  Future<void> _poll() async {
    if (!_connected ||
        _busy ||
        _polling ||
        _adjustingGain ||
        _adjustingParameter) {
      return;
    }
    _polling = true;
    try {
      final status = await _backend.send('status');
      if (mounted) {
        setState(() {
          _status = status;
          if (status['failed'] == true) _error = '音频设备已中断，请检查连接后重新开始监听。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _connected = false;
          _status = {};
          _error = '$error';
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _send(
    String command, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final status = await _backend.send(command, args);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _status = status;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _queueParameter(int index, int parameter, double value) {
    _pendingParameter = {
      'index': index,
      'parameter': parameter,
      'value': value,
    };
    _parameterTimer ??= Timer(
      const Duration(milliseconds: 40),
      _flushParameter,
    );
  }

  void _flushParameter() {
    _parameterTimer?.cancel();
    _parameterTimer = null;
    final args = _pendingParameter;
    _pendingParameter = null;
    if (args == null) return;
    unawaited(
      _backend
          .send('parameter', args)
          .then((status) {
            if (mounted) setState(() => _status = status);
          })
          .catchError((Object error) {
            if (mounted) setState(() => _error = '$error');
          }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native plugin/settings windows may temporarily take focus (inactive).
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (_connected) {
        unawaited(
          _backend
              .send('stop')
              .then((status) {
                if (mounted) setState(() => _status = status);
              })
              .catchError((Object error) {
                if (mounted) setState(() => _error = '$error');
              }),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _parameterTimer?.cancel();
    _path.dispose();
    unawaited(_backend.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supported = _backend.supported;
    final canEdit = supported && !_busy && !_running;
    return Scaffold(
      appBar: AppBar(title: const Text('实时效果器')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('让琴声经过你的效果链', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              '吉他 → 声卡乐器输入 → 内置 / VST3 效果链 → 耳机。使用耳机试听，先降低输出音量；声卡直通监听会混入未处理的干声。',
            ),
            if (!supported) ...[
              const SizedBox(height: 16),
              const Text('此功能目前仅面向 Linux 和 Windows 桌面。'),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: canEdit ? () => _send('settings') : null,
                  icon: const Icon(Icons.settings_input_component),
                  label: const Text('声卡与输入通道'),
                ),
                FilledButton.icon(
                  onPressed: supported && !_busy
                      ? () => _send(_running ? 'stop' : 'start')
                      : null,
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(_running ? '停止监听' : '开始监听'),
                ),
                if (!_connected)
                  TextButton(
                    onPressed: supported && !_busy
                        ? () => _send('status')
                        : null,
                    child: const Text('连接引擎'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('监听缓冲：越小反应越快；出现爆音、断续时调到 256 或 512 帧。停止监听后调整。'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final frames in [64, 128, 256, 512])
                  ChoiceChip(
                    label: Text('$frames 帧'),
                    selected: (_status['requestedBuffer'] ?? 128) == frames,
                    onSelected: canEdit
                        ? (_) => _send('audioBuffer', {'frames': frames})
                        : null,
                  ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _running ? '正在监听' : '监听已停止',
                      style: theme.textTheme.titleMedium,
                    ),
                    if (_connected) ...[
                      Text(
                        '${_status['backend'] ?? ''} · ${_status['device'] ?? ''}',
                      ),
                      if (_status['inputDevice'] != null)
                        Text(
                          '输入：${_status['inputDevice']}\n输出：${_status['outputDevice']}',
                        ),
                      Text(
                        _status['audioOpen'] == false
                            ? '音频设备已关闭；重新开始后显示实际缓冲和延迟。'
                            : '${_status['sampleRate']} Hz · 实际 ${_status['bufferSize']} 帧'
                                  ' · 每块 ${(_status['blockMs'] as num? ?? 0).toStringAsFixed(2)} ms',
                      ),
                      Text(
                        '驱动报告：输入 ${(_status['inputLatencyMs'] as num? ?? 0).toStringAsFixed(1)} ms'
                        ' / 输出 ${(_status['outputLatencyMs'] as num? ?? 0).toStringAsFixed(1)} ms'
                        ' · 插件 ${(_status['pluginLatencyMs'] as num? ?? 0).toStringAsFixed(1)} ms',
                      ),
                      Text(
                        '报告合计 ${(_status['latencyMs'] as num? ?? 0).toStringAsFixed(1)} ms（非实测往返延迟）'
                        ' · 音频负载 ${((_status['cpu'] as num? ?? 0) * 100).toStringAsFixed(1)}%'
                        '${(_status['xruns'] as num? ?? -1) >= 0 ? ' · 欠载 ${_status['xruns']} 次' : ''}',
                      ),
                      if ((_status['pipewireQuantum'] as String? ?? '')
                          .isNotEmpty)
                        Text(
                          'PipeWire 活动节点请求：${_status['pipewireQuantum']}；关闭音频设备后解除，可能临时影响同图其他应用。',
                        ),
                      if ((_status['setupNotice'] as String? ?? '').isNotEmpty)
                        Text(_status['setupNotice'] as String),
                      if ((_status['bufferSize'] as num? ?? 0) >
                          (_status['requestedBuffer'] as num? ?? 128))
                        const Text('实际缓冲大于请求值，请检查声卡后端及系统音频限制。'),
                      if ((_status['latencyMs'] as num? ?? 0) >= 20)
                        const Text(
                          '报告延迟偏高：优先使用同一声卡的输入和有线耳机输出；可在声卡设置中尝试直接硬件设备或 JACK。',
                        ),
                      if ((_status['wetOnly'] as List? ?? []).isNotEmpty)
                        const Text('当前有全湿混响或延迟：先降低干湿比或旁通，再判断监听延迟，回声时间属于效果本身。'),
                    ],
                    const SizedBox(height: 12),
                    _meter(
                      '输入',
                      (_status['inputPeak'] as num? ?? 0).toDouble(),
                    ),
                    const SizedBox(height: 8),
                    _meter(
                      '输出',
                      (_status['outputPeak'] as num? ?? 0).toDouble(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '输出音量 ${((_status['gain'] as num? ?? 0.5) * 100).round()}%',
                    ),
                    Slider(
                      value: (_status['gain'] as num? ?? 0.5).toDouble().clamp(
                        0,
                        1,
                      ),
                      onChanged: _connected && !_busy
                          ? (value) => setState(
                              () => _status = {..._status, 'gain': value},
                            )
                          : null,
                      onChangeStart: (_) => _adjustingGain = true,
                      onChangeEnd: (value) {
                        _adjustingGain = false;
                        if (_connected) {
                          unawaited(_send('gain', {'value': value}));
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '效果链 · ${_plugins.length}/8',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              '从上到下依次处理，可重复添加同一种效果。监听时可调节参数与旁通；停止监听后可添加、移除和上下排序。效果链与参数仅在本次页面内保留。',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final effect in const [
                  ('fuzz', 'Fuzz 法兹'),
                  ('compressor', '压缩'),
                  ('reverb', '混响'),
                  ('overdrive', '过载'),
                  ('delay', '延迟'),
                ])
                  OutlinedButton.icon(
                    onPressed: canEdit && _plugins.length < 8
                        ? () => _send('builtin', {'kind': effect.$1})
                        : null,
                    icon: const Icon(Icons.add),
                    label: Text(effect.$2),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('也可加载当前系统和 CPU 架构对应的 .vst3 插件，输入插件的绝对路径。'),
            const SizedBox(height: 12),
            TextField(
              controller: _path,
              enabled: canEdit,
              decoration: const InputDecoration(
                labelText: 'VST3 插件绝对路径',
                hintText: '/home/you/.vst3/MyEffect.vst3',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: canEdit && _plugins.length < 8
                    ? () => _send('load', {'path': _path.text.trim()})
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('加载插件'),
              ),
            ),
            if (_plugins.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('效果链为空，开始监听将输出原始琴声。'),
              ),
            for (var i = 0; i < _plugins.length; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}. ${_plugins[i]['name']}',
                        style: theme.textTheme.titleMedium,
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          FilterChip(
                            label: const Text('旁通'),
                            selected: _plugins[i]['bypass'] == true,
                            onSelected: !_busy
                                ? (value) => _send('bypass', {
                                    'index': i,
                                    'value': value,
                                  })
                                : null,
                          ),
                          if ((_plugins[i]['kind'] ?? 'vst3') == 'vst3')
                            TextButton(
                              onPressed: !_busy
                                  ? () => _send('editor', {'index': i})
                                  : null,
                              child: const Text('参数窗口'),
                            ),
                          IconButton(
                            tooltip: '上移',
                            onPressed: canEdit && i > 0
                                ? () => _send('move', {
                                    'index': i,
                                    'destination': i - 1,
                                  })
                                : null,
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            tooltip: '下移',
                            onPressed: canEdit && i + 1 < _plugins.length
                                ? () => _send('move', {
                                    'index': i,
                                    'destination': i + 1,
                                  })
                                : null,
                            icon: const Icon(Icons.arrow_downward),
                          ),
                          IconButton(
                            tooltip: '移除',
                            onPressed: canEdit
                                ? () => _send('remove', {'index': i})
                                : null,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      if (_plugins[i]['parameters'] is List)
                        for (
                          var parameter = 0;
                          parameter <
                              (_plugins[i]['parameters'] as List).length;
                          parameter++
                        )
                          _ParameterSlider(
                            key: ValueKey(
                              '$i-${_plugins[i]['kind']}-$parameter',
                            ),
                            parameter: Map<String, dynamic>.from(
                              _plugins[i]['parameters'][parameter] as Map,
                            ),
                            enabled: _connected && !_busy,
                            onStart: () => _adjustingParameter = true,
                            onChanged: (value) =>
                                _queueParameter(i, parameter, value),
                            onEnd: () {
                              _adjustingParameter = false;
                              _flushParameter();
                            },
                          ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _meter(String label, double peak) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label${peak >= 1 ? ' · 削波，请降低增益' : ''}'),
      LinearProgressIndicator(
        value: peak.clamp(0, 1),
        minHeight: 8,
        color: peak >= 1 ? Theme.of(context).colorScheme.error : null,
      ),
    ],
  );
}

class _ParameterSlider extends StatefulWidget {
  const _ParameterSlider({
    super.key,
    required this.parameter,
    required this.enabled,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });
  final Map<String, dynamic> parameter;
  final bool enabled;
  final VoidCallback onStart;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;
  @override
  State<_ParameterSlider> createState() => _ParameterSliderState();
}

class _ParameterSliderState extends State<_ParameterSlider> {
  bool _dragging = false;
  double? _value;
  @override
  Widget build(BuildContext context) {
    final p = widget.parameter;
    final value = _dragging ? _value! : (p['value'] as num).toDouble();
    final min = (p['min'] as num).toDouble();
    final max = (p['max'] as num).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${p['name']} · ${value.toStringAsFixed(max > 100 ? 0 : 2)} ${p['unit']}',
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          semanticFormatterCallback: (value) =>
              '${p['name']} ${value.toStringAsFixed(2)} ${p['unit']}',
          onChangeStart: (_) {
            _dragging = true;
            _value = value;
            widget.onStart();
          },
          onChanged: widget.enabled
              ? (value) {
                  setState(() => _value = value);
                  widget.onChanged(value);
                }
              : null,
          onChangeEnd: (_) {
            setState(() => _dragging = false);
            widget.onEnd();
          },
        ),
      ],
    );
  }
}
