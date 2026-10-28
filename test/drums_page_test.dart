import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drums_page.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

class FakeDrumAudio implements MetronomeAudio {
  bool playing = false;
  MetronomePattern? pattern;
  double gain = 1;
  @override
  void setGain(double value) => gain = value;
  @override
  Future<void> unlock() async {}
  @override
  Future<void> prepare(MetronomePattern pattern) async {
    this.pattern = pattern;
  }

  @override
  void play() {
    playing = true;
  }

  @override
  Duration get position => Duration.zero;
  @override
  void silence() {
    playing = false;
  }

  @override
  Future<void> clear() async {
    playing = false;
  }

  @override
  Future<void> dispose() async {
    playing = false;
  }
}

void main() {
  testWidgets('preset playback, stop and narrow large text layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final audio = FakeDrumAudio();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: DrumsPage(audio: audio),
        ),
      ),
    );
    await tester.ensureVisible(find.text('布鲁斯'));
    await tester.tap(find.text('布鲁斯'));
    await tester.pump();
    expect(find.textContaining('摇摆 33%'), findsOneWidget);
    await tester.ensureVisible(find.text('开始伴奏'));
    await tester.tap(find.text('开始伴奏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(audio.playing, isTrue);
    expect(audio.pattern!.beats, 4);
    await tester.tap(find.text('停止伴奏'));
    await tester.pump();
    expect(audio.playing, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
