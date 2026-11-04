import 'package:flutter/material.dart';
import '../../tuner/tuner_page.dart';
import '../../drums/drums_page.dart';
import '../../chords/chords_page.dart';
import '../../scales/scales_page.dart';
import '../../metronome/metronome_page.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('吉他宝典')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.graphic_eq,
                          color: colors.onPrimaryContainer,
                          size: 32,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '每一次拨弦，\n都更进一步。',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '调准琴弦，找到节奏，开始今天的练习。',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  const _ToolGroup(
                    title: '01  练习准备',
                    description: '从准确的音高与稳定的节奏开始',
                    tools: [
                      _Tool(
                        '吉他调音器',
                        '标准六弦调音 · 实时音高与偏差',
                        Icons.tune,
                        TunerPage(),
                      ),
                      _Tool(
                        '节拍器',
                        '稳定节奏 · 速度调节与首拍重音',
                        Icons.timer_outlined,
                        MetronomePage(),
                      ),
                    ],
                  ),
                  const _ToolGroup(
                    title: '02  理解与练习',
                    description: '把乐理变成指尖上的声音',
                    tools: [
                      _Tool(
                        '和弦练习',
                        '12 课循序学习 · 三和弦、转位与常见七和弦',
                        Icons.music_note,
                        ChordsPage(),
                      ),
                      _Tool(
                        '音阶指板',
                        '各调常用音阶 · CAGED / 一弦三音',
                        Icons.grid_on,
                        ScalesPage(),
                      ),
                    ],
                  ),
                  const _ToolGroup(
                    title: '03  即兴创作',
                    description: '让节奏陪你，把灵感叠成音乐',
                    tools: [
                      _Tool(
                        '即兴工作台',
                        '鼓机伴奏 · Looper 叠录与实时效果器',
                        Icons.queue_music,
                        DrumsPage(),
                      ),
                    ],
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

class _Tool {
  const _Tool(this.title, this.description, this.icon, this.page);
  final String title;
  final String description;
  final IconData icon;
  final Widget page;
}

class _ToolGroup extends StatelessWidget {
  const _ToolGroup({
    required this.title,
    required this.description,
    required this.tools,
  });
  final String title;
  final String description;
  final List<_Tool> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns =
                  constraints.maxWidth >= 700 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 24;
              // 只有一张卡片时铺满整行，避免宽屏出现半宽的孤卡。
              final columns = twoColumns && tools.length > 1 ? 2 : 1;
              final cardWidth =
                  (constraints.maxWidth - 16 * (columns - 1)) / columns;
              return Wrap(
                spacing: 16,
                runSpacing: 4,
                children: tools
                    .map(
                      (tool) => SizedBox(
                        width: cardWidth,
                        child: Card.filled(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => tool.page,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color:
                                          theme.colorScheme.secondaryContainer,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Icon(
                                      tool.icon,
                                      color: theme
                                          .colorScheme
                                          .onSecondaryContainer,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          tool.title,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          tool.description,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.arrow_forward,
                                    size: 20,
                                    color: theme.colorScheme.primary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
