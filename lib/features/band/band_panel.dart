import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/brand.dart';
import 'band_controller.dart';
import 'chord_progression.dart';

/// 乐队 · 和弦进行 面板：开关、进行选择、演奏方式与音量。
///
/// 面板自己监听控制器，控制器状态一变就重建，不需要外部再包一层。
class BandPanel extends StatelessWidget {
  const BandPanel({super.key, required this.controller});

  final BandController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _panel(context),
    );
  }

  Widget _panel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chord = controller.currentChord;
    return Container(
      key: const ValueKey('band-panel'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.outlineVariant),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ToolIllustration(asset: AppAssets.band, size: 44, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BAND CHORDS',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 2,
                        color: colors.primary,
                      ),
                    ),
                    Text(
                      '乐队 · 和弦进行',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Chip(
                key: const ValueKey('band-chord'),
                label: Text(chord?.shortName ?? '—'),
                avatar: const Icon(Icons.music_note, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('和弦进行', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final progression in bandProgressions)
                ChoiceChip(
                  key: ValueKey('band-progression-${progression.name}'),
                  label: Text(progression.name),
                  selected: controller.progression == progression,
                  showCheckmark: false,
                  onSelected: (selected) {
                    if (selected) controller.setProgression(progression);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('演奏方式', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final style in ChordPlayStyle.values)
                ChoiceChip(
                  key: ValueKey('band-style-${style.name}'),
                  label: Text(style.label),
                  selected: controller.style == style,
                  showCheckmark: false,
                  onSelected: (selected) {
                    if (selected) controller.setStyle(style);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          _volume(context),
          const SizedBox(height: 8),
          Text(_status(controller), style: Theme.of(context).textTheme.labelLarge),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                controller.error!,
                style: TextStyle(color: colors.error),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('band-toggle'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () {
              if (controller.playing) {
                unawaited(controller.disable());
              } else {
                unawaited(controller.enable());
              }
            },
            icon: Icon(
              controller.playing
                  ? Icons.stop_rounded
                  : Icons.play_arrow_rounded,
            ),
            label: Text(controller.playing ? '停止和弦进行' : '开始和弦进行'),
          ),
          const SizedBox(height: 10),
          Text(
            '跟着鼓机的速度演奏和弦进行 · 切换进行时不会跳回第一小节',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _volume(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.volume_down, size: 20),
        Expanded(
          child: Slider(
            key: const ValueKey('band-volume'),
            value: controller.volume,
            divisions: 100,
            label: '${(controller.volume * 100).round()}%',
            semanticFormatterCallback: (value) =>
                '和弦音量 ${(value * 100).round()}%',
            onChanged: controller.setVolume,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(controller.volume * 100).round()}%',
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ],
    );
  }

  /// 面板下方的状态说明。
  String _status(BandController controller) {
    if (!controller.enabled) return '未开启 · 开启后与鼓机同步演奏';
    final chord = controller.currentChord;
    if (chord == null) return '正在准备和弦…';
    return '正在演奏 ${chord.name} · ${controller.progression.name}';
  }
}
