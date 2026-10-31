import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A physical-style series board: instrument on the right, output on the left.
class PedalBoard extends StatefulWidget {
  const PedalBoard({
    super.key,
    required this.plugins,
    required this.enabled,
    required this.onCommand,
    required this.onParameterStart,
    required this.onParameter,
    required this.onParameterEnd,
  });

  final List<dynamic> plugins;
  final bool enabled;
  final void Function(String, Map<String, dynamic>) onCommand;
  final VoidCallback onParameterStart;
  final void Function(int, int, double) onParameter;
  final VoidCallback onParameterEnd;

  @override
  State<PedalBoard> createState() => _PedalBoardState();
}

class _PedalBoardState extends State<PedalBoard> {
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  Timer? _edgeTimer;
  double _edgeStep = 0;

  void _endDrag() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgeStep = 0;
  }

  void _dragUpdate(DragUpdateDetails details) {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final local = box.globalToLocal(details.globalPosition);
    final x = local.dx;
    if (local.dy < 0 || local.dy > box.size.height) {
      _edgeStep = 0;
      return;
    }
    // The horizontal scroll view is reversed: increasing offset reveals the left.
    _edgeStep = x < 40
        ? 12
        : x > box.size.width - 40
        ? -12
        : 0;
    _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scroll.hasClients || _edgeStep == 0) return;
      _scroll.jumpTo(
        (_scroll.offset + _edgeStep).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  void dispose() {
    _endDrag();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final width = 204.0 + (scale - 1).clamp(0, 2) * 100;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label:
          '信号链：吉他输入 → ${widget.plugins.map((p) => p["name"]).join(" → ")}${widget.plugins.isEmpty ? "" : " → "}输出（右进左出）',
      child: Container(
        key: const ValueKey('pedal-board'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF202324),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF515658), width: 3),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text(
                    'GUITARBOOK  /  PEDALBOARD',
                    style: TextStyle(
                      color: Color(0xFFD5D8D7),
                      fontSize: 12,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '输出  ←  信号方向  ←  吉他输入',
                    style: TextStyle(color: Color(0xFFB9C8BC), fontSize: 12),
                  ),
                ],
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final boardWidth = math.max(
                  constraints.maxWidth,
                  widget.plugins.length * width +
                      math.max(0, widget.plugins.length - 1) * 48 +
                      144,
                );
                return ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                    },
                  ),
                  child: Scrollbar(
                    key: _viewport,
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      key: const PageStorageKey('pedal-board-scroll'),
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: SizedBox(
                        width: boardWidth,
                        child: CustomPaint(
                          painter: _BoardPainter(
                            count: widget.plugins.length,
                            pedalWidth: width,
                            labelStyle: Theme.of(context).textTheme.labelSmall!,
                          ),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              widget.plugins.isEmpty
                                  ? 20
                                  : (boardWidth -
                                            widget.plugins.length * width -
                                            math.max(
                                                  0,
                                                  widget.plugins.length - 1,
                                                ) *
                                                48) /
                                        2,
                              22,
                              widget.plugins.isEmpty
                                  ? 20
                                  : (boardWidth -
                                            widget.plugins.length * width -
                                            math.max(
                                                  0,
                                                  widget.plugins.length - 1,
                                                ) *
                                                48) /
                                        2,
                              28,
                            ),
                            child: widget.plugins.isEmpty
                                ? const SizedBox(
                                    height: 280,
                                    child: Center(
                                      child: Padding(
                                        padding: EdgeInsets.only(top: 100),
                                        child: Text(
                                          '你的第一块单块，等你接上\n从效果库添加，空板输出原始琴声。',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Color(0xFFCBD0CF),
                                            height: 1.8,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (
                                        var i = widget.plugins.length - 1;
                                        i >= 0;
                                        i--
                                      ) ...[
                                        if (i < widget.plugins.length - 1)
                                          const SizedBox(width: 48),
                                        SizedBox(
                                          width: width,
                                          child: DragTarget<int>(
                                            onWillAcceptWithDetails:
                                                (details) =>
                                                    widget.enabled &&
                                                    details.data != i,
                                            onAcceptWithDetails: (details) {
                                              _endDrag();
                                              widget.onCommand('move', {
                                                'index': details.data,
                                                'destination': i,
                                              });
                                            },
                                            builder:
                                                (
                                                  context,
                                                  candidates,
                                                  rejected,
                                                ) => DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                    boxShadow:
                                                        candidates.isEmpty
                                                        ? []
                                                        : const [
                                                            BoxShadow(
                                                              color: Color(
                                                                0xFFFFE6A0,
                                                              ),
                                                              spreadRadius: 4,
                                                              blurRadius: 8,
                                                            ),
                                                          ],
                                                  ),
                                                  child: _Pedal(
                                                    key: ValueKey('pedal-$i'),
                                                    dragUpdate: _dragUpdate,
                                                    dragEnd: _endDrag,
                                                    index: i,
                                                    plugin:
                                                        Map<
                                                          String,
                                                          dynamic
                                                        >.from(
                                                          widget.plugins[i]
                                                              as Map,
                                                        ),
                                                    enabled: widget.enabled,
                                                    canMoveForward: i > 0,
                                                    canMoveBackward:
                                                        i <
                                                        widget.plugins.length -
                                                            1,
                                                    onCommand: widget.onCommand,
                                                    onParameterStart:
                                                        widget.onParameterStart,
                                                    onParameter:
                                                        (parameter, value) =>
                                                            widget.onParameter(
                                                              i,
                                                              parameter,
                                                              value,
                                                            ),
                                                    onParameterEnd:
                                                        widget.onParameterEnd,
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                '拖动顶部把手排序，板边缘自动滚动 · 拖动底板浏览 · 旋钮上下调节 · 脚踏切换旁通',
                style: TextStyle(color: Color(0xFFB8BEBC), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pedal extends StatelessWidget {
  const _Pedal({
    super.key,
    required this.dragUpdate,
    required this.dragEnd,
    required this.index,
    required this.plugin,
    required this.enabled,
    required this.canMoveForward,
    required this.canMoveBackward,
    required this.onCommand,
    required this.onParameterStart,
    required this.onParameter,
    required this.onParameterEnd,
  });
  final void Function(DragUpdateDetails) dragUpdate;
  final VoidCallback dragEnd;
  final int index;
  final Map<String, dynamic> plugin;
  final bool enabled, canMoveForward, canMoveBackward;
  final void Function(String, Map<String, dynamic>) onCommand;
  final VoidCallback onParameterStart, onParameterEnd;
  final void Function(int, double) onParameter;

  @override
  Widget build(BuildContext context) {
    final kind = plugin['kind'] ?? 'vst3';
    final (color, title, subtitle) = switch (kind) {
      'amp_clean' => (const Color(0xFF446A76), 'US CLEAN', '美式清音 / 箱头'),
      'amp_chime' => (const Color(0xFF8B683D), 'UK CHIME', '英式清脆 / 箱头'),
      'amp_crunch' => (const Color(0xFF776137), 'UK CRUNCH', '英式摇滚 / 箱头'),
      'amp_modern' => (const Color(0xFF575666), 'MODERN', '现代高增益 / 箱头'),
      'wah' => (const Color(0xFF913E60), 'WAH', '扫频共振 / 哇音'),
      'fuzz' => (const Color(0xFFB84B32), 'FUZZ', '粗粝颗粒 / 法兹'),
      'compressor' => (const Color(0xFF81611E), 'COMP', '动态控制 / 压缩'),
      'reverb' => (const Color(0xFF625383), 'REVERB', '空间漫游 / 混响'),
      'overdrive' => (const Color(0xFF497753), 'OVERDRIVE', '温暖饱和 / 过载'),
      'delay' => (const Color(0xFF356E91), 'DELAY', '时间回声 / 延迟'),
      _ => (const Color(0xFF52616C), 'VST3', '外部音色'),
    };
    final bypass = plugin['bypass'] == true;
    final parameters = plugin['parameters'] as List? ?? [];
    // This local theme preserves the pedal's printed labels in both app themes.
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: color,
          brightness: Brightness.dark,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(color, Colors.white, .16)!,
              color,
              Color.lerp(color, Colors.black, .3)!,
            ],
          ),
          border: Border.all(
            color: Color.lerp(color, Colors.black, .65)!,
            width: 3,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0xCC000000),
              blurRadius: 5,
              offset: Offset(5, 10),
            ),
            BoxShadow(color: Color(0x66000000), offset: Offset(0, 5)),
          ],
        ),
        child: Stack(
          children: [
            const Positioned(top: 8, left: 8, child: _Screw()),
            const Positioned(top: 8, right: 8, child: _Screw()),
            const Positioned(bottom: 8, left: 8, child: _Screw()),
            const Positioned(bottom: 8, right: 8, child: _Screw()),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
              child: Column(
                children: [
                  Draggable<int>(
                    key: ValueKey('pedal-drag-$index'),
                    data: index,
                    maxSimultaneousDrags: enabled ? 1 : 0,
                    onDragUpdate: dragUpdate,
                    onDragEnd: (_) => dragEnd(),
                    onDraggableCanceled: (_, _) => dragEnd(),
                    feedback: Material(
                      elevation: 8,
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '${index + 1}. ${plugin['name']}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                    child: MouseRegion(
                      cursor: enabled
                          ? SystemMouseCursors.grab
                          : SystemMouseCursors.basic,
                      child: Tooltip(
                        message: '拖动排序',
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          alignment: Alignment.center,
                          child: Column(
                            children: [
                              const Icon(
                                Icons.drag_handle,
                                color: Color(0xFFFFF3D8),
                              ),
                              Text(
                                '${index + 1}. ${plugin['name']}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFFFFF3D8),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '◀ OUT',
                        style: TextStyle(
                          color: Color(0xFFFFF3D8),
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        'IN ◀',
                        style: TextStyle(
                          color: Color(0xFFFFF3D8),
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (kind == 'wah' && parameters.length > 4)
                    Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile(
                        key: ValueKey('wah-mode-$index'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          (parameters[4]['value'] as num) >= 0.5 ? '自动' : '手动',
                          style: const TextStyle(color: Color(0xFFFFF3D8)),
                        ),
                        value: (parameters[4]['value'] as num) >= 0.5,
                        onChanged: enabled
                            ? (value) {
                                onParameterStart();
                                onParameter(4, value ? 1 : 0);
                                onParameterEnd();
                              }
                            : null,
                      ),
                    ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 14,
                    children: [
                      for (var p = 0; p < parameters.length; p++)
                        if (kind != 'wah' ||
                            (p != 4 &&
                                (p < 5 ||
                                    (parameters[4]['value'] as num) >= 0.5)))
                          PedalKnob(
                            key: ValueKey('$index-$kind-$p'),
                            parameter: Map<String, dynamic>.from(
                              parameters[p] as Map,
                            ),
                            enabled: enabled,
                            onStart: onParameterStart,
                            onChanged: (value) => onParameter(p, value),
                            onEnd: onParameterEnd,
                          ),
                    ],
                  ),
                  if (kind == 'vst3')
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: OutlinedButton(
                        onPressed: enabled
                            ? () => onCommand('editor', {'index': index})
                            : null,
                        child: const Text('参数窗口'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFFFF3D8),
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFF9E8C8),
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xAA18201D),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.black38),
                    ),
                    child: Column(
                      children: [
                        Container(
                          key: ValueKey('pedal-led-$index-${!bypass}'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: bypass
                                ? const Color(0xFF4E4B42)
                                : const Color(0xFFFFE6A0),
                            border: Border.all(color: Colors.black54),
                            boxShadow: bypass
                                ? []
                                : const [
                                    BoxShadow(
                                      color: Color(0xFFFFBF50),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Semantics(
                          button: true,
                          toggled: !bypass,
                          label:
                              '${index + 1}号 ${plugin['name']}，${bypass ? '已旁通' : '效果开启'}，切换脚踏',
                          child: Tooltip(
                            message: bypass ? '开启效果' : '旁通',
                            child: IconButton(
                              key: ValueKey('pedal-switch-$index'),
                              onPressed: enabled
                                  ? () => onCommand('bypass', {
                                      'index': index,
                                      'value': !bypass,
                                    })
                                  : null,
                              style: IconButton.styleFrom(
                                padding: const EdgeInsets.all(8),
                              ),
                              icon: Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFFF4F4ED),
                                      Color(0xFF7D8486),
                                      Color(0xFFE1E3DF),
                                      Color(0xFF737C80),
                                    ],
                                  ),
                                  border: Border.all(
                                    color: const Color(0xFF343A3D),
                                    width: 3,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black54,
                                      offset: Offset(0, 3),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Container(
                                    width: 25,
                                    height: 25,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFFB9BFBE),
                                      border: Border.all(
                                        color: const Color(0xFFF2F3E9),
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Text(
                          bypass ? 'BYPASS · 已旁通' : 'ON · 效果开启',
                          style: const TextStyle(
                            color: Color(0xFFE7E8D8),
                            fontSize: 10,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      IconButton(
                        key: ValueKey('pedal-forward-$index'),
                        tooltip: '前移',
                        onPressed: enabled && canMoveForward
                            ? () => onCommand('move', {
                                'index': index,
                                'destination': index - 1,
                              })
                            : null,
                        icon: const Icon(Icons.arrow_forward, size: 18),
                      ),
                      IconButton(
                        key: ValueKey('pedal-backward-$index'),
                        tooltip: '后移',
                        onPressed: enabled && canMoveBackward
                            ? () => onCommand('move', {
                                'index': index,
                                'destination': index + 1,
                              })
                            : null,
                        icon: const Icon(Icons.arrow_back, size: 18),
                      ),
                      IconButton(
                        key: ValueKey('pedal-remove-$index'),
                        tooltip: '移除',
                        onPressed: enabled
                            ? () => onCommand('remove', {'index': index})
                            : null,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                  const Text(
                    'GUITARBOOK',
                    style: TextStyle(
                      color: Color(0xCCFFF3D8),
                      fontSize: 9,
                      letterSpacing: 3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Screw extends StatelessWidget {
  const _Screw();
  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const LinearGradient(
        colors: [Color(0xFFE1E2DC), Color(0xFF626768)],
      ),
      border: Border.all(color: Colors.black54),
    ),
    child: const Center(
      child: SizedBox(
        width: 5,
        child: Divider(height: 1, thickness: 1, color: Color(0xFF3B4041)),
      ),
    ),
  );
}

/// Drag vertically like a hardware knob; tap for precise, accessible adjustment.
class PedalKnob extends StatefulWidget {
  const PedalKnob({
    super.key,
    required this.parameter,
    required this.enabled,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });
  final Map<String, dynamic> parameter;
  final bool enabled;
  final VoidCallback onStart, onEnd;
  final ValueChanged<double> onChanged;
  @override
  State<PedalKnob> createState() => _PedalKnobState();
}

class _PedalKnobState extends State<PedalKnob> {
  double? _local;
  bool _dragging = false;
  bool _focused = false;
  double get _min => (widget.parameter['min'] as num).toDouble();
  double get _max => (widget.parameter['max'] as num).toDouble();
  double get _value => (_local ?? (widget.parameter['value'] as num).toDouble())
      .clamp(_min, _max);
  String _format(double value) =>
      '${value.toStringAsFixed(_max > 100 ? 0 : 2)} ${widget.parameter['unit']}'
          .trim();
  void _change(double value) {
    final next = value.clamp(_min, _max);
    setState(() => _local = next);
    widget.onChanged(next);
  }

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    widget.onEnd();
    if (mounted) setState(() => _local = null);
  }

  void _step(double direction) {
    if (!widget.enabled) return;
    widget.onStart();
    _change(_value + direction * (_max - _min) / 100);
    widget.onEnd();
    setState(() => _local = null);
  }

  Future<void> _precise() async {
    if (!widget.enabled) return;
    widget.onStart();
    var value = _value;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text('${widget.parameter['name']}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_format(value)),
                Slider(
                  value: value,
                  min: _min,
                  max: _max,
                  onChanged: (next) {
                    update(() => value = next);
                    _change(next);
                  },
                ),
              ],
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
    } finally {
      widget.onEnd();
      if (mounted) setState(() => _local = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fraction = (_value - _min) / (_max - _min);
    return SizedBox(
      width:
          52 +
          (MediaQuery.textScalerOf(context).scale(14) / 14 - 1).clamp(0, 2) *
              32,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.enter): _precise,
        },
        child: Focus(
          canRequestFocus: widget.enabled,
          onFocusChange: (value) {
            if (mounted) setState(() => _focused = value);
          },
          child: Semantics(
            excludeSemantics: true,
            onTap: widget.enabled ? _precise : null,
            label: '${widget.parameter['name']}',
            value: _format(_value),
            enabled: widget.enabled,
            increasedValue: _format(
              (_value + (_max - _min) / 100).clamp(_min, _max),
            ),
            decreasedValue: _format(
              (_value - (_max - _min) / 100).clamp(_min, _max),
            ),
            onIncrease: widget.enabled ? () => _step(1) : null,
            onDecrease: widget.enabled ? () => _step(-1) : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? _precise : null,
              onVerticalDragStart: widget.enabled
                  ? (_) {
                      _local = _value;
                      _dragging = true;
                      widget.onStart();
                    }
                  : null,
              onVerticalDragUpdate: widget.enabled
                  ? (details) =>
                        _change(_value - details.delta.dy * (_max - _min) / 160)
                  : null,
              onVerticalDragEnd: widget.enabled ? (_) => _endDrag() : null,
              onVerticalDragCancel: widget.enabled ? _endDrag : null,
              child: Column(
                children: [
                  Text(
                    '${widget.parameter['name']}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFFFF3D8),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  CustomPaint(
                    painter: _KnobPainter(fraction, focused: _focused),
                    size: const Size(52, 52),
                  ),
                  Text(
                    _format(_value),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFFFF3D8),
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
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

class _KnobPainter extends CustomPainter {
  const _KnobPainter(this.value, {this.focused = false});
  final bool focused;
  final double value;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 72);
    const center = Offset(36, 36);
    if (focused) {
      canvas.drawCircle(
        center,
        35,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFFFF3D8),
      );
    }
    for (var i = 0; i <= 10; i++) {
      final angle = math.pi * (.75 + i * .15);
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * 30,
        center + direction * 33,
        Paint()
          ..color = const Color(0xFFEDDCB9)
          ..strokeWidth = 1.5,
      );
    }
    canvas.drawCircle(
      center + const Offset(2, 4),
      24,
      Paint()..color = Colors.black45,
    );
    canvas.drawCircle(
      center,
      25,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF5E6360), Color(0xFF0E1211)],
        ).createShader(Rect.fromCircle(center: center, radius: 25)),
    );
    for (var i = 0; i < 28; i++) {
      final angle = i * math.pi / 14;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * 21,
        center + direction * 24,
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1,
      );
    }
    canvas.drawCircle(center, 19, Paint()..color = const Color(0xFF242A27));
    final angle = math.pi * (.75 + value * 1.5);
    final direction = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      center + direction * 8,
      center + direction * 20,
      Paint()
        ..color = const Color(0xFFFFF3D8)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter oldDelegate) =>
      value != oldDelegate.value || focused != oldDelegate.focused;
}

class _BoardPainter extends CustomPainter {
  const _BoardPainter({
    required this.count,
    required this.pedalWidth,
    required this.labelStyle,
  });
  final int count;
  final double pedalWidth;
  final TextStyle labelStyle;
  @override
  void paint(Canvas canvas, Size size) {
    void cable(double left, double right, {bool curved = true}) {
      const y = 90.0;
      final path = Path()..moveTo(left, y);
      if (curved) {
        path.cubicTo(left + 15, y + 52, right - 15, y + 52, right, y);
      } else {
        path.lineTo(right, y);
      }
      canvas.drawPath(
        path.shift(const Offset(1, 4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = Colors.black54,
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = const Color(0xFF111716),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF75917E),
      );
      for (final x in [left, right]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, y), width: 15, height: 17),
            const Radius.circular(3),
          ),
          Paint()
            ..shader = const LinearGradient(
              colors: [Color(0xFFB7BEBA), Color(0xFF565E5E), Color(0xFFD4D8CF)],
            ).createShader(Rect.fromLTWH(x - 8, y - 9, 16, 18)),
        );
        canvas.drawCircle(
          Offset(x, y),
          3,
          Paint()..color = const Color(0xFF1C2421),
        );
      }
      final mid = (left + right) / 2;
      final arrowY = curved ? y + 39 : y;
      canvas.drawPath(
        Path()
          ..moveTo(mid + 4, arrowY - 4)
          ..lineTo(mid - 2, arrowY)
          ..lineTo(mid + 4, arrowY + 4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFD1DCC9),
      );
    }

    if (count == 0) {
      cable(40, size.width - 40, curved: false);
    } else {
      final start = (size.width - count * pedalWidth - (count - 1) * 48) / 2;
      cable(40, start);
      for (var i = 0; i < count - 1; i++) {
        final left = start + i * (pedalWidth + 48) + pedalWidth;
        cable(left, left + 48);
      }
      cable(
        start + (count - 1) * (pedalWidth + 48) + pedalWidth,
        size.width - 40,
      );
    }
    for (final (x, label) in [(24.0, 'OUT'), (size.width - 62, 'IN')]) {
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: labelStyle.copyWith(
            color: const Color(0xFFD5D8D7),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(x, 56));
    }
  }

  @override
  bool shouldRepaint(_BoardPainter oldDelegate) =>
      oldDelegate.count != count ||
      oldDelegate.pedalWidth != pedalWidth ||
      oldDelegate.labelStyle != labelStyle;
}
