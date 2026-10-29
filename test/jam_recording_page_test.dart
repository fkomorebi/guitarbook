import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drums_page.dart';
import 'package:guitarbook/features/jam_recording/save_recording_native.dart';
import 'package:guitarbook/features/jam_recording/recording_buffer.dart';
import 'drums_page_test.dart' show FakeDrumAudio;
import 'jam_layout_test.dart' show UnsupportedEffects;
import 'looper_test.dart' show FakeInput, FakeOutput;

class TestPaths extends PathProviderPlatform {
  TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Future<void> settleInput(WidgetTester tester) async {
  // Stream cancellation crosses real async futures and the widget fake clock.
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pumpAndSettle();
}

void main() {
  test('saved WAV exists in documents and retains PCM bytes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'guitarbook-recording-',
    );
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = TestPaths(directory.path);
    try {
      final buffer = RecordingBuffer(8)
        ..add(.25)
        ..add(-.5);
      final wav = buffer.toWav();
      final path = await saveRecording(wav);
      expect(path, startsWith('${directory.path}/Guitarbook Recordings/'));
      expect(await File(path).readAsBytes(), wav);
    } finally {
      PathProviderPlatform.instance = previous;
      await directory.delete(recursive: true);
    }
  });
  testWidgets('workspace records, enables save and stops input in background', (
    tester,
  ) async {
    final input = FakeInput();
    final preview = FakeOutput();
    await tester.pumpWidget(
      MaterialApp(
        home: DrumsPage(
          audio: FakeDrumAudio(),
          effectsBackend: UnsupportedEffects(),
          recordingInput: input,
          previewFactory: () => preview,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('开始录音'));
    await tester.pump();
    expect(input.active, isTrue);
    expect(find.byTooltip('音频输入正在使用'), findsOneWidget);
    input.emit(480);
    await tester.pump();
    await tester.tap(find.text('停止录音'));
    await settleInput(tester);
    expect(input.active, isFalse);
    await tester.tap(find.text('试听录音'));
    await tester.pump();
    expect(preview.playing, isTrue);
    expect(preview.pattern!.samples.length, 480);
    expect(preview.pattern!.samples.first, closeTo(12000 / 32768, .0001));
    await tester.pump(const Duration(milliseconds: 20));
    expect(preview.playing, isFalse);
    expect(preview.disposed, isTrue);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '保存'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('开始录音'));
    await tester.pump();
    expect(input.active, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settleInput(tester);
    expect(input.active, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(input.active, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
