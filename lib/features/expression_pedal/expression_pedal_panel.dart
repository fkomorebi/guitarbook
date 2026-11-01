import 'package:flutter/material.dart';

import 'expression_pedal_controller.dart';
import 'gamepad_trigger.dart';

/// 效果链里可被手柄扳机控制的目标（目前只有哇音）。
class WahTarget {
  const WahTarget({required this.index, required this.name});

  final int index;
  final String name;

  String get label => '$name #${index + 1}';
}

/// 效果器页里的“手柄线性扳机 → 哇音踏板”设置卡片。
class ExpressionPedalPanel extends StatelessWidget {
  const ExpressionPedalPanel({
    super.key,
    required this.controller,
    required this.canConfigure,
    required this.wahTargets,
    required this.targetIndex,
    required this.onTargetChanged,
    required this.onEnabledChanged,
    required this.running,
    required this.autoMode,
  });

  final ExpressionPedalController controller;
  final bool canConfigure;
  final List<WahTarget> wahTargets;
  final int? targetIndex;
  final ValueChanged<int?> onTargetChanged;
  final ValueChanged<bool> onEnabledChanged;
  final bool running;
  final bool autoMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.sports_esports),
                title: Text('手柄线性扳机 → 哇音踏板'),
                subtitle: Text('用游戏手柄的线性扳机连续控制哇音位置（350–2200 Hz），像表情踏板一样扫频。'),
              ),
              if (!controller.supported)
                _hint(theme, controller.platformNote ?? '当前平台不支持读取手柄线性扳机。')
              else ...[
                SwitchListTile(
                  key: const ValueKey('expression-pedal-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用手柄踏板'),
                  subtitle: Text(_statusText()),
                  value: controller.enabled,
                  onChanged: canConfigure ? onEnabledChanged : null,
                ),
                if (controller.enabled) ..._activeControls(context, theme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _activeControls(BuildContext context, ThemeData theme) {
    final index = wahTargets.any((target) => target.index == targetIndex)
        ? targetIndex
        : null;
    final value = controller.value;
    return [
      Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<PedalTrigger>(
            key: const ValueKey('expression-pedal-trigger'),
            segments: [
              for (final trigger in PedalTrigger.values)
                ButtonSegment(value: trigger, label: Text(trigger.label)),
            ],
            selected: {controller.trigger},
            onSelectionChanged: (selection) =>
                controller.setTrigger(selection.first),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('反向'),
              Switch(
                key: const ValueKey('expression-pedal-invert'),
                value: controller.invert,
                onChanged: controller.setInvert,
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 12),
      DropdownButton<int>(
        key: const ValueKey('expression-pedal-target'),
        value: index,
        isExpanded: true,
        hint: const Text('选择要控制的哇音'),
        items: [
          for (final target in wahTargets)
            DropdownMenuItem(value: target.index, child: Text(target.label)),
        ],
        onChanged: onTargetChanged,
      ),
      if (wahTargets.isEmpty) _hint(theme, '先在效果链中添加“哇音 Wah”，再启用扳机控制。'),
      if (wahTargets.isNotEmpty && index == null) _hint(theme, '请选择要控制的哇音。'),
      if (autoMode) _hint(theme, '目标哇音处于自动扫频模式；切到手动后扳机才会接管位置。'),
      if (!running) _hint(theme, '开始监听后，扳机位置才会写入效果器。'),
      const SizedBox(height: 12),
      Row(
        children: [
          const SizedBox(width: 64, child: Text('踏板位置')),
          Expanded(
            child: LinearProgressIndicator(
              value: value,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 48,
            child: Text(
              '${(value * 100).round()}%',
              key: const ValueKey('expression-pedal-value'),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        '原始读数 ${controller.rawValue ?? '—'} · '
        '量程 ${controller.minRaw}–${controller.maxRaw}'
        '${controller.calibrated ? '（已校准）' : '（默认量程）'}',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            key: const ValueKey('expression-pedal-calibrate-min'),
            onPressed: controller.rawValue == null
                ? null
                : controller.captureMin,
            child: const Text('记录最低点'),
          ),
          OutlinedButton(
            key: const ValueKey('expression-pedal-calibrate-max'),
            onPressed: controller.rawValue == null
                ? null
                : controller.captureMax,
            child: const Text('记录最高点'),
          ),
          TextButton(
            key: const ValueKey('expression-pedal-reset-calibration'),
            onPressed: controller.calibrated
                ? controller.resetCalibration
                : null,
            child: const Text('重置校准'),
          ),
        ],
      ),
      _hint(
        theme,
        '校准：松开扳机点“记录最低点”，踩到底点“记录最高点”。'
        '不同手柄量程不同（常见 0–255 或 0–1023）。',
      ),
      if (controller.platformNote != null)
        _hint(theme, controller.platformNote!),
    ];
  }

  String _statusText() {
    switch (controller.status) {
      case GamepadInputStatus.unsupported:
        return '当前平台不支持读取手柄';
      case GamepadInputStatus.searching:
        return controller.error ?? '正在查找手柄…';
      case GamepadInputStatus.ready:
        return controller.deviceName.isEmpty
            ? '已连接手柄'
            : '已连接：${controller.deviceName}';
      case GamepadInputStatus.error:
        return controller.error ?? '读取手柄失败';
    }
  }

  Widget _hint(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
