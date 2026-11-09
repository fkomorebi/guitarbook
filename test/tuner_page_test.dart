import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/tuner/tuner_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // record 插件在构造 AudioRecorder 时就会调用通道，桩掉它避免 MissingPluginException。
  const channel = MethodChannel('com.llfbandit.record/messages');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('默认 440 Hz 基准并可切换到 432 Hz', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TunerPage()));
    await tester.pump();

    expect(find.text('A4 = 440 Hz'), findsOneWidget);
    expect(find.text('A4 = 432 Hz'), findsOneWidget);
    expect(find.text('标准调弦 · A4 = 440 Hz'), findsOneWidget);
    expect(find.text('目标 82.41 Hz'), findsOneWidget);
    expect(find.text('国际标准基准 · 目标频率与常规一致'), findsOneWidget);

    await tester.tap(find.text('A4 = 432 Hz'));
    await tester.pump();

    expect(find.text('标准调弦 · A4 = 432 Hz'), findsOneWidget);
    expect(find.text('目标 80.91 Hz'), findsOneWidget);
    expect(find.text('自然音准 · 全部目标频率比 440 Hz 低约 31.8 音分'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
