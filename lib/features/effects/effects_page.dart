import 'dart:async';

import 'package:flutter/material.dart';

import 'effects_backend.dart';
import 'pedal_board.dart';

class EffectsPage extends StatefulWidget {
  const EffectsPage({super.key, this.backend, this.embedded = false});

  final bool embedded;

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
  int _revision = 0;
  bool _adjustingGain = false;
  bool _adjustingParameter = false;
  Timer? _parameterTimer;
  Map<String, dynamic>? _pendingParameter;
  bool _connected = false;
  bool _available = false;
  int _lifecycleRevision = 0;
  String? _error;

  bool get _running => _status['running'] == true;
  List<dynamic> get _plugins => _status['plugins'] as List<dynamic>? ?? [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_backend.supported) {
      unawaited(_send(widget.embedded ? 'probe' : 'start'));
    }
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
    final revision = _revision;
    try {
      final status = await _backend.send('status');
      if (mounted && revision == _revision) {
        setState(() {
          _status = status;
          if (status['failed'] == true) _error = '音频设备已中断，请检查连接后重新开始监听。';
        });
      }
    } catch (error) {
      if (mounted && revision == _revision) {
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
    _revision++;
    final lifecycleRevision = _lifecycleRevision;
    setState(() => _busy = true);
    try {
      var status = await _backend.send(command, args);
      if (command == 'start' && lifecycleRevision != _lifecycleRevision) {
        status = await _backend.send('stop');
      }
      if (!mounted) return;
      setState(() {
        _connected = true;
        _status = status;
        if (command == 'probe') _available = status['available'] == true;
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
      _lifecycleRevision++;
      _revision++;
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
    final canEdit = supported && !_busy;
    final canConfigure = canEdit && !_running;
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1480),
        child: ListView(
          shrinkWrap: widget.embedded,
          primary: !widget.embedded,
          physics: widget.embedded
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '你的单块效果器板',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.embedded
                  ? '效果器与伴奏可同时使用。点击开始监听才会出声；Looper 录入效果器处理后的声音（48 kHz 单声道），已录层保留当时音色。请使用声卡有线耳机，关闭直通监听。'
                  : '插上吉他，边弹边塑造音色。进入即监听，效果可随时添加、旁通与调整。请使用声卡有线耳机，关闭直通监听。',
            ),
            if (widget.embedded && supported) ...[
              const SizedBox(height: 8),
              Text(
                _busy
                    ? '正在检查效果器与音频设备…'
                    : _running
                    ? '效果器监听中，可同时调节鼓机与 Looper 音量。'
                    : _available && _error == null
                    ? '检测通过：引擎和音频输入/输出可用，尚未开始监听。'
                    : '可用性以设备实际打开结果为准；连接或权限变化后可重新检测。',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: !_busy && !_running ? () => _send('probe') : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新检测'),
                ),
              ),
            ],
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
                  onPressed: canConfigure ? () => _send('settings') : null,
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide =
                        constraints.maxWidth >= 700 &&
                        MediaQuery.textScalerOf(context).scale(14) < 22;
                    final meters = [
                      _meter(
                        '输入',
                        (_status['inputPeak'] as num? ?? 0).toDouble(),
                      ),
                      _meter(
                        '输出',
                        (_status['outputPeak'] as num? ?? 0).toDouble(),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '输出音量 ${((_status['gain'] as num? ?? 0.5) * 100).round()}%',
                          ),
                          Slider(
                            key: const ValueKey('effects-volume'),
                            value: (_status['gain'] as num? ?? 0.5)
                                .toDouble()
                                .clamp(0, 1),
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
                    ];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _running ? '正在监听' : '监听已停止',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        if (wide)
                          Row(
                            children: [
                              for (var i = 0; i < meters.length; i++) ...[
                                if (i > 0) const SizedBox(width: 24),
                                Expanded(child: meters[i]),
                              ],
                            ],
                          )
                        else ...[
                          for (final meter in meters)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: meter,
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '效果链 · ${_plugins.length}/8',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text('像真实单块一样，右侧输入、向左串联。旋钮塑造音色，脚踏切换旁通；最多 8 块。'),
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
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _effectColor(effect.$1),
                    ),
                    onPressed: canEdit && _plugins.length < 8
                        ? () => _send('builtin', {'kind': effect.$1})
                        : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(effect.$2),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            PedalBoard(
              key: const ValueKey('effects-board'),
              plugins: _plugins,
              enabled: _connected && !_busy,
              onCommand: (command, args) => _send(command, args),
              onParameterStart: () => _adjustingParameter = true,
              onParameter: _queueParameter,
              onParameterEnd: () {
                _adjustingParameter = false;
                _flushParameter();
              },
            ),
            const SizedBox(height: 20),
            Card(
              child: ExpansionTile(
                key: const PageStorageKey('effects-vst3'),
                title: const Text('外部 VST3 插件'),
                subtitle: const Text('加载已安装的插件'),
                childrenPadding: const EdgeInsets.all(16),
                children: [
                  const Text('也可加载当前系统和 CPU 架构对应的 .vst3 插件，输入插件的绝对路径。'),
                  const SizedBox(height: 12),
                  TextField(
                    key: const PageStorageKey('effects-vst3-path'),
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
                ],
              ),
            ),
            Card(
              child: ExpansionTile(
                key: const PageStorageKey('effects-diagnostics'),
                title: const Text('声卡设置与延迟诊断'),
                subtitle: const Text('缓冲 · 设备 · 性能'),
                childrenPadding: const EdgeInsets.all(16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  const Text('监听缓冲：越小反应越快；出现爆音、断续时调到 256 或 512 帧。停止监听后调整。'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final frames in [64, 128, 256, 512])
                        ChoiceChip(
                          label: Text('$frames 帧'),
                          selected:
                              (_status['requestedBuffer'] ?? 128) == frames,
                          onSelected: canConfigure
                              ? (_) => _send('audioBuffer', {'frames': frames})
                              : null,
                        ),
                    ],
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return widget.embedded
        ? content
        : Scaffold(
            appBar: AppBar(title: const Text('实时效果器')),
            body: SafeArea(child: content),
          );
  }

  Color _effectColor(dynamic kind) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (kind) {
      'fuzz' => Color(dark ? 0xFFFFB59A : 0xFFA34225),
      'compressor' => Color(dark ? 0xFFE4CD83 : 0xFF80651A),
      'reverb' => Color(dark ? 0xFFCAB8EF : 0xFF71529C),
      'overdrive' => Color(dark ? 0xFFA4D69A : 0xFF326B31),
      'delay' => Color(dark ? 0xFF9BCCED : 0xFF356E91),
      _ => Theme.of(context).colorScheme.primary,
    };
  }

  Widget _meter(String label, double peak) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label${peak >= 1 ? ' · 削波，请降低增益' : ''}'),
      LinearProgressIndicator(
        value: peak.clamp(0, 1),
        minHeight: 8,
        borderRadius: BorderRadius.circular(8),
        color: peak >= 1 ? Theme.of(context).colorScheme.error : null,
      ),
    ],
  );
}
