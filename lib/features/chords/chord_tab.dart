import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import 'chord_lesson.dart';

/// A free-time practice staff, rather than a rhythm or playback score.
class ChordTab extends StatefulWidget {
  const ChordTab({
    super.key,
    required this.chords,
    this.selectedIndex = 0,
    this.onSelected,
  }) : assert(chords.length > 0),
       assert(selectedIndex >= 0 && selectedIndex < chords.length);

  final List<GuitarChord> chords;
  final int selectedIndex;
  final ValueChanged<int>? onSelected;

  @override
  State<ChordTab> createState() => _ChordTabState();
}

class _ChordTabState extends State<ChordTab> {
  final _scrollController = ScrollController();
  double _columnWidth = 104;
  double _clefWidth = 46;

  @override
  void didUpdateWidget(covariant ChordTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.chords.length != widget.chords.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final position = _scrollController.position;
        final left = _clefWidth + widget.selectedIndex * _columnWidth;
        final right = left + _columnWidth;
        final target = widget.selectedIndex == 0
            ? 0.0
            : left < position.pixels
            ? left
            : right > position.pixels + position.viewportDimension
            ? right - position.viewportDimension
            : position.pixels;
        _scrollController.jumpTo(target.clamp(0.0, position.maxScrollExtent));
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final paper = dark ? const Color(0xFF202224) : Colors.white;
    final ink = dark ? const Color(0xFFEAE8E3) : const Color(0xFF202020);
    final line = ink.withValues(alpha: dark ? 0.55 : 0.65);
    final accent = dark ? const Color(0xFFDFC09C) : const Color(0xFF795548);
    final scaler = MediaQuery.textScalerOf(context);
    final spacing = scaler.scale(13);
    final heading = scaler.scale(18) + 18;
    final staffHeight = spacing * 6;
    final barHeight = spacing * 5;
    final scoreStyle = TextStyle(
      fontFamily: 'ScoreSerif',
      fontSize: 13,
      height: 1,
      color: ink,
    );

    Widget strings(int column, {required Widget child}) => SizedBox(
      height: staffHeight,
      child: Stack(
        children: [
          for (var string = 1; string <= 6; string++)
            Positioned(
              top: spacing * (string - 0.5) - 0.3,
              left: 0,
              right: 0,
              child: ColoredBox(
                key: ValueKey('tab-line-$column-$string'),
                color: line,
                child: const SizedBox(height: 0.6),
              ),
            ),
          child,
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        _clefWidth = scaler.scale(46);
        // Keep short exercises compact instead of stretching two chords across a card.
        _columnWidth =
            ((constraints.maxWidth - 32 - _clefWidth) / widget.chords.length)
                .clamp(scaler.scale(104), scaler.scale(152));
        return DecoratedBox(
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: ink.withValues(alpha: 0.10)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  key: const ValueKey('chord-tab-scroll'),
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: SizedBox(
                          width: _clefWidth,
                          child: Column(
                            children: [
                              SizedBox(height: heading),
                              strings(
                                -1,
                                child: Positioned.fill(
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Positioned(
                                        left: 0,
                                        top: spacing / 2,
                                        child: Container(
                                          width: 0.8,
                                          height: barHeight,
                                          color: ink,
                                        ),
                                      ),
                                      ColoredBox(
                                        color: paper,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 3,
                                          ),
                                          child: Text(
                                            'T\nA\nB',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 20,
                                              height: 1,
                                              fontWeight: FontWeight.w500,
                                              color: ink,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      for (var index = 0; index < widget.chords.length; index++)
                        Semantics(
                          key: ValueKey('tab-column-$index'),
                          button: widget.onSelected != null,
                          selected: widget.onSelected == null
                              ? null
                              : index == widget.selectedIndex,
                          label:
                              '${index + 1}，${widget.chords[index].name}，${List.generate(6, (i) => widget.chords[index].instruction(5 - i)).join('；')}',
                          child: InkWell(
                            onTap: widget.onSelected == null
                                ? null
                                : () => widget.onSelected!(index),
                            child: ExcludeSemantics(
                              child: SizedBox(
                                width: _columnWidth,
                                child: Column(
                                  children: [
                                    SizedBox(
                                      height: heading,
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              widget.chords[index].name,
                                              style: scoreStyle.copyWith(
                                                fontSize: 15,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Container(
                                              width: 16,
                                              height: 2,
                                              color:
                                                  widget.onSelected != null &&
                                                      index ==
                                                          widget.selectedIndex
                                                  ? accent
                                                  : Colors.transparent,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    strings(
                                      index,
                                      child: Positioned.fill(
                                        child: Stack(
                                          children: [
                                            for (
                                              var string = 1;
                                              string <= 6;
                                              string++
                                            )
                                              if (widget.chords[index].frets[6 -
                                                      string] >=
                                                  0)
                                                Positioned(
                                                  top: spacing * (string - 1),
                                                  left: 0,
                                                  right: 0,
                                                  height: spacing,
                                                  child: Center(
                                                    child: Container(
                                                      key: ValueKey(
                                                        'tab-$index-string-$string',
                                                      ),
                                                      color: paper,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 2.5,
                                                          ),
                                                      child: Text(
                                                        '${widget.chords[index].frets[6 - string]}',
                                                        style: scoreStyle,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            Positioned(
                                              key: ValueKey(
                                                'tab-barline-$index',
                                              ),
                                              right: 0,
                                              top: spacing / 2,
                                              height: barHeight,
                                              child: Row(
                                                children: [
                                                  Container(
                                                    width: 0.8,
                                                    color: ink,
                                                  ),
                                                  if (index ==
                                                      widget.chords.length -
                                                          1) ...[
                                                    const SizedBox(width: 3),
                                                    Container(
                                                      width: 2.5,
                                                      color: ink,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
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
      },
    );
  }
}
