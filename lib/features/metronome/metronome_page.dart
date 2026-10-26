import 'package:flutter/material.dart';

import 'metronome_audio.dart';
import 'metronome_audio_factory.dart';
import 'metronome_controller.dart';

class MetronomePage extends StatefulWidget {
  const MetronomePage({super.key, this.audio});

  final MetronomeAudio? audio;

  @override
  State<MetronomePage> createState() => _MetronomePageState();
}

class _MetronomePageState extends State<MetronomePage>
    with WidgetsBindingObserver {
  late final MetronomeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MetronomeController(widget.audio ?? createMetronomeAudio())
      ..addListener(_refresh);
    WidgetsBinding.instance.addObserver(this);
  }

  void _refresh() => setState(() {});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller.stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_refresh);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('节拍器')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${c.bpm} BPM',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      IconButton(
                        tooltip: '减慢 1 BPM',
                        onPressed: c.bpm > 30
                            ? () => c.configure(bpm: c.bpm - 1)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Expanded(
                        child: Slider(
                          label: '${c.bpm} BPM',
                          value: c.bpm.toDouble(),
                          min: 30,
                          max: 240,
                          divisions: 210,
                          onChanged: (value) => c.configure(bpm: value.round()),
                        ),
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
                  const SizedBox(height: 16),
                  Text(
                    c.preparing
                        ? '正在准备声音…'
                        : c.running
                        ? '第 ${c.beat} / ${c.beats} 拍'
                        : '准备好，跟着节拍拍奏',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: List.generate(c.beats, (index) {
                      final active = c.running && c.beat == index + 1;
                      return Semantics(
                        label: '第 ${index + 1} 拍',
                        selected: active,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: active
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  DropdownButtonFormField<int>(
                    initialValue: c.beats,
                    decoration: const InputDecoration(
                      labelText: '每小节拍数',
                      border: OutlineInputBorder(),
                    ),
                    items: List.generate(
                      12,
                      (index) => DropdownMenuItem(
                        value: index + 1,
                        child: Text('${index + 1} 拍'),
                      ),
                    ),
                    onChanged: (value) {
                      if (value != null) c.configure(beats: value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('首拍重音'),
                    value: c.accent,
                    onChanged: (value) => c.configure(accent: value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('播放声音'),
                    value: c.sound,
                    onChanged: (value) => c.configure(sound: value),
                  ),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        c.error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: c.running ? c.stop : c.start,
                    icon: Icon(c.running ? Icons.stop : Icons.play_arrow),
                    label: Text(c.running ? '停止节拍' : '开始节拍'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '离开页面或进入后台会停止。声音受系统音量与静音设置影响；蓝牙设备可能增加延迟。',
                    textAlign: TextAlign.center,
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
