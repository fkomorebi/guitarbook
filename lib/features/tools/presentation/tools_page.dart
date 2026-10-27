import 'package:flutter/material.dart';
import '../../tuner/tuner_page.dart';
import '../../chords/chords_page.dart';
import '../../scales/scales_page.dart';
import '../../metronome/metronome_page.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('吉他宝典')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('你的吉他工具集合', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 12),
                  Text('让练习更专注，让音乐更近一步。', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 32),
                  Card.filled(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(24),
                      leading: const Icon(Icons.music_note),
                      title: const Text('和弦练习'),
                      subtitle: const Text('12 课循序学习 · 三和弦、转位与常见七和弦'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ChordsPage(),
                        ),
                      ),
                    ),
                  ),
                  Card.filled(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(24),
                      leading: const Icon(Icons.grid_on),
                      title: const Text('音阶指板'),
                      subtitle: const Text('各调常用音阶 · CAGED / 一弦三音'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ScalesPage(),
                        ),
                      ),
                    ),
                  ),
                  Card.filled(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(24),
                      leading: const Icon(Icons.tune),
                      title: const Text('吉他调音器'),
                      subtitle: const Text('标准六弦调音 · 实时音高与偏差'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TunerPage(),
                        ),
                      ),
                    ),
                  ),
                  Card.filled(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(24),
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('节拍器'),
                      subtitle: const Text('稳定节奏 · 速度调节与首拍重音'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MetronomePage(),
                        ),
                      ),
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
