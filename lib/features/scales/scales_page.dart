import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'scale_pattern.dart';
import 'scale_guide.dart';

class ScalesPage extends StatefulWidget {
  const ScalesPage({super.key});
  @override
  State<ScalesPage> createState() => _ScalesPageState();
}

class _ScalesPageState extends State<ScalesPage> {
  final _fretboardController = ScrollController();

  @override
  void dispose() {
    _fretboardController.dispose();
    super.dispose();
  }

  int root = 0;
  int scaleIndex = 0;
  int position = 0;
  bool threeNotes = false;
  bool degrees = false;

  @override
  Widget build(BuildContext context) {
    final scale = scaleTypes[scaleIndex];
    final guide = scaleGuides[scale.name]!;
    final notes = buildPattern(root, scale, threeNotes, position);
    final firstFret = notes.map((n) => n.fret).reduce((a, b) => a < b ? a : b);
    final lastFret = notes.map((n) => n.fret).reduce((a, b) => a > b ? a : b);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('音阶指板')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ExplanationCard(
                    title: '先认识音阶',
                    children: const [
                      Text(
                        '音阶是从一个主音出发，按一定音程关系排列的一组音。它提供写旋律、练耳和即兴时可参考的音，不是必须按顺序弹的曲子。',
                      ),
                      Text(
                        '主音是听觉上的中心，记作 1 级。选 C 为主音、选大调，就是 C 大调：C、D、E、F、G、A、B，再回到高八度 C。换主音会整体移调，音阶的音程关系保持不变。',
                      ),
                      Text(
                        '级数表示音与主音的关系。这里以同主音大调作参照，♭3 是把大调第 3 级降低半音，♯4 是把第 4 级升高半音。吉他相邻两品差半音，两品差全音。',
                      ),
                      Text(
                        '指板会标出所选音阶在各条弦上的音。同一个音可出现在不同弦、不同八度；实色是当前把位，描边是根音。CAGED 与一弦三音提供不同的指板组织方式，切换它们不改变所选音阶。',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: root,
                    decoration: const InputDecoration(labelText: '主音 / 调'),
                    items: List.generate(
                      12,
                      (i) =>
                          DropdownMenuItem(value: i, child: Text(rootNames[i])),
                    ),
                    onChanged: (value) => setState(() => root = value!),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: scaleIndex,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '音阶'),
                    items: List.generate(
                      scaleTypes.length,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text(scaleTypes[i].name),
                      ),
                    ),
                    onChanged: (value) => setState(() {
                      scaleIndex = value!;
                      position = 0;
                    }),
                  ),
                  const SizedBox(height: 16),
                  _ExplanationCard(
                    key: ValueKey(scale.name),
                    title: '${rootNames[root]} · ${scale.name}',
                    children: [
                      Text('结构特点：${guide.character}'),
                      Text('听感与用途：${guide.sound}'),
                      Text('怎么练：${guide.practice}'),
                      Text(
                        '先找根音 ${noteNames[root]}，慢慢弹完所选音阶，再回到 ${noteNames[root]}。先练一个把位，再连接其他把位；换起点并不自动改变调式，主音中心和伴奏也很关键。',
                      ),
                      const Text(
                        '听感描述只是参考，同一音阶也能表现不同情绪。先跟着听、再用短句练习，比一次背完所有把位更容易理解。',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('CAGED 系统'),
                        selected: !threeNotes,
                        onSelected: (_) => setState(() {
                          threeNotes = false;
                          position = 0;
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('一弦三音系统'),
                        selected: threeNotes,
                        onSelected: (_) => setState(() {
                          threeNotes = true;
                          position = 0;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(
                      threeNotes ? scale.intervals.length : 5,
                      (i) => ChoiceChip(
                        label: Text(
                          threeNotes
                              ? '把位 ${i + 1} · ${scale.degrees[i]} 级起'
                              : '${cagedShapes[i]} 形把位',
                        ),
                        selected: position == i,
                        onSelected: (_) => setState(() => position = i),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示音阶级数'),
                    subtitle: const Text('只显示音阶内音；实色为当前指型；描边为根音'),
                    value: degrees,
                    onChanged: (value) => setState(() => degrees = value),
                  ),
                  Text(
                    '音阶组成：${scale.intervals.map((n) => noteNames[(root + n) % 12]).join(' · ')}',
                  ),
                  Text('级数：${scale.degrees.join(' · ')}'),
                  const SizedBox(height: 16),
                  Text('标准调弦 · 一弦在上，六弦在下 · $firstFret–$lastFret 品'),
                  const SizedBox(height: 8),
                  Text(
                    '拖动指板或底部滚动条查看全部品位${lastFret > 22 ? ' · 此指型超出 22 品，已延伸展示，需更多品数的吉他' : ''}',
                  ),
                  const SizedBox(height: 12),
                  ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.trackpad,
                        PointerDeviceKind.stylus,
                        PointerDeviceKind.invertedStylus,
                      },
                    ),
                    child: Scrollbar(
                      controller: _fretboardController,
                      thumbVisibility: true,
                      trackVisibility: true,
                      interactive: true,
                      scrollbarOrientation: ScrollbarOrientation.bottom,
                      child: SingleChildScrollView(
                        key: const ValueKey('fretboard-scroll'),
                        controller: _fretboardController,
                        padding: const EdgeInsets.only(bottom: 20),
                        scrollDirection: Axis.horizontal,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    const SizedBox(width: 64),
                                    for (
                                      var fret = 0;
                                      fret <= (lastFret > 22 ? lastFret : 22);
                                      fret++
                                    )
                                      SizedBox(
                                        width: 80,
                                        child: Center(
                                          child: Text(
                                            fret == 0 ? '空弦' : '$fret',
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                for (var string = 5; string >= 0; string--)
                                  Row(
                                    children: [
                                      SizedBox(
                                        width: 64,
                                        child: Center(
                                          child: Text(
                                            '${6 - string}  ${['E', 'A', 'D', 'G', 'B', 'E'][string]}',
                                          ),
                                        ),
                                      ),
                                      for (
                                        var fret = 0;
                                        fret <= (lastFret > 22 ? lastFret : 22);
                                        fret++
                                      )
                                        Builder(
                                          builder: (context) {
                                            final matches = notes.where(
                                              (n) =>
                                                  n.string == string &&
                                                  n.fret == fret,
                                            );
                                            final selected = matches.isNotEmpty;
                                            final pitchClass =
                                                (openStrings[string] + fret) %
                                                12;
                                            final degree = scale.intervals
                                                .indexOf(
                                                  (pitchClass - root) % 12,
                                                );
                                            final isRoot = degree == 0;
                                            final label = degrees && degree >= 0
                                                ? scale.degrees[degree]
                                                : noteNames[pitchClass];
                                            final background = selected
                                                ? colors.primary
                                                : degree >= 0
                                                ? colors.secondaryContainer
                                                : colors.surfaceContainerLow;
                                            final foreground = selected
                                                ? colors.onPrimary
                                                : degree >= 0
                                                ? colors.onSecondaryContainer
                                                : colors.onSurfaceVariant;
                                            final height =
                                                56.0 *
                                                MediaQuery.textScalerOf(
                                                  context,
                                                ).scale(1);
                                            return SizedBox(
                                              width: 80,
                                              height: height,
                                              child: Stack(
                                                alignment: Alignment.center,
                                                children: [
                                                  Positioned(
                                                    left: 0,
                                                    right: 0,
                                                    child: Container(
                                                      height:
                                                          1 +
                                                          (5 - string) * .25,
                                                      color: colors.outline,
                                                    ),
                                                  ),
                                                  Positioned(
                                                    top: 0,
                                                    bottom: 0,
                                                    right: 0,
                                                    child: Container(
                                                      width: fret == 0
                                                          ? 5
                                                          : 1.5,
                                                      color: fret == 0
                                                          ? colors.onSurface
                                                          : colors
                                                                .outlineVariant,
                                                    ),
                                                  ),
                                                  if (degree >= 0)
                                                    Semantics(
                                                      label:
                                                          '${6 - string}弦 $fret品 $label${isRoot ? ' 根音' : ''}${selected ? ' 当前指型' : ''}',
                                                      child: Container(
                                                        constraints:
                                                            const BoxConstraints(
                                                              minWidth: 38,
                                                              minHeight: 38,
                                                            ),
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 6,
                                                              vertical: 8,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: background,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                24,
                                                              ),
                                                          border: Border.all(
                                                            color: isRoot
                                                                ? colors.primary
                                                                : selected
                                                                ? colors
                                                                      .onPrimary
                                                                : colors
                                                                      .outlineVariant,
                                                            width: isRoot
                                                                ? 3
                                                                : 1,
                                                          ),
                                                        ),
                                                        child: Text(
                                                          label,
                                                          textAlign:
                                                              TextAlign.center,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            color: foreground,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const SizedBox(width: 64),
                                    for (
                                      var fret = 0;
                                      fret <= (lastFret > 22 ? lastFret : 22);
                                      fret++
                                    )
                                      SizedBox(
                                        width: 80,
                                        child: Center(
                                          child: Text(
                                            [
                                                  3,
                                                  5,
                                                  7,
                                                  9,
                                                  15,
                                                  17,
                                                  19,
                                                  21,
                                                ].contains(fret)
                                                ? '●'
                                                : fret == 12 || fret == 24
                                                ? '● ●'
                                                : '',
                                            style: TextStyle(
                                              color: colors.outline,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    threeNotes
                        ? '每弦连续三个音阶音，从六弦向一弦上行。${scale.intervals.length < 7 ? '五声和布鲁斯音阶跨度较大，需要伸展或换把。' : ''}'
                        : 'CAGED 按五种和弦形的把位区域展示区域内全部音阶音，不代表和弦指法或固定手指编号。',
                  ),
                  const SizedBox(height: 8),
                  const Text('升降音同时列出等音名称；本工具不按调号进行严格拼写。设置仅在本页保留，无需麦克风权限。'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExplanationCard extends StatelessWidget {
  const _ExplanationCard({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            for (final child in children) ...[
              const SizedBox(height: 12),
              child,
            ],
          ],
        ),
      ),
    );
  }
}
