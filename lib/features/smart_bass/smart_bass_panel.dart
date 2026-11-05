import 'package:flutter/material.dart';

import 'bass_pattern.dart';
import 'chord_detector.dart';
import 'smart_bass_controller.dart';

/// 智能base 面板：开关、风格、音量与识别到的和弦。
class SmartBassPanel extends StatelessWidget {
  const SmartBassPanel({super.key, required this.controller});

  final SmartBassController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chord = controller.chord;
    return Container(
      key: const ValueKey('smart-bass-panel'),
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
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.graphic_eq,
                  color: colors.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SMART BASS',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 2,
                        color: colors.primary,
                      ),
                    ),
                    Text(
                      '智能base',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (chord != null)
                Chip(
                  key: const ValueKey('smart-bass-chord'),
                  label: Text(chord.name),
                  avatar: const Icon(Icons.music_note, size: 18),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('低音风格', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final style in BassStyle.values)
                ChoiceChip(
                  key: ValueKey('smart-bass-style-${style.name}'),
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
          Text(
            _status(controller),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (chord != null)
            Text(
              '识别把握 ${(chord.confidence * 100).round()}%',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
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
            key: const ValueKey('smart-bass-toggle'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: controller.enabled
                ? () => controller.disable()
                : () => controller.enable(),
            icon: Icon(
              controller.enabled
                  ? Icons.stop_rounded
                  : Icons.play_arrow_rounded,
            ),
            label: Text(controller.enabled ? '停止智能base' : '开启智能base'),
          ),
          const SizedBox(height: 10),
          Text(
            '识别当前输入的和弦并自动整点低音 · 和弦变化落在下一拍',
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
            key: const ValueKey('smart-bass-volume'),
            value: controller.volume,
            divisions: 100,
            label: '${(controller.volume * 100).round()}%',
            semanticFormatterCallback: (value) =>
                '低音音量 ${(value * 100).round()}%',
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

  String _status(SmartBassController controller) {
    if (!controller.enabled) return '未开启 · 开启后跟着你弹的和弦走';
    if (!controller.listening) return '正在连接输入…';
    final chord = controller.chord;
    if (chord == null) return '等待琴声 · 弹一个和弦就能识别';
    return controller.playing
        ? '低音已跟上 ${chord.name}'
        : '识别到 ${chord.name} · 正在准备低音';
  }
}

/// 和弦识别的展示文案，便于测试与界面复用。
String smartBassChordLabel(ChordDetection? chord) =>
    chord == null ? '未识别' : chord.name;
