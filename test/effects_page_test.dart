import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/effects/effects_backend.dart';
import 'package:guitarbook/features/effects/effects_page.dart';
import 'package:guitarbook/features/effects/pedal_board.dart';

class FakeEffects extends EffectsBackend {
  final calls = <String>[];
  final requests = <Map<String, dynamic>>[];
  bool running = false;
  bool released = false;
  bool fail = false;
  int frames = 128;
  double gain = 0.5;
  Completer<void>? starting;
  final plugins = <Map<String, dynamic>>[];

  @override
  bool get supported => true;

  @override
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    calls.add(command);
    requests.add({'command': command, ...arguments});
    if (fail) throw StateError('测试设备中断');
    if (command == 'gain') gain = (arguments['value'] as num).toDouble();
    if (command == 'audioBuffer') frames = arguments['frames'] as int;
    if (command == 'start') {
      await starting?.future;
      running = true;
    }
    if (command == 'stop') running = false;
    if (command == 'load') plugins.add({'name': 'Test Gain', 'bypass': false});
    if (command == 'builtin') {
      final kind = arguments['kind'] as String;
      plugins.add({
        'name': {
          'fuzz': 'Fuzz 法兹',
          'compressor': '压缩 Compressor',
          'reverb': '混响 Reverb',
          'overdrive': '过载 Overdrive',
          'delay': '延迟 Delay',
          'amp_clean': '美式清音箱头',
          'amp_chime': '英式清脆箱头',
          'amp_crunch': '英式摇滚箱头',
          'amp_modern': '现代高增益箱头',
        }[kind],
        'kind': kind,
        'bypass': false,
        'parameters': kind.startsWith('amp_')
            ? [
                {
                  'name': '增益',
                  'min': 0.0,
                  'max': 10.0,
                  'value': 4.0,
                  'unit': '',
                },
                for (final name in ['低频', '中频', '高频'])
                  {
                    'name': name,
                    'min': -12.0,
                    'max': 12.0,
                    'value': 0.0,
                    'unit': 'dB',
                  },
                {
                  'name': '主音量',
                  'min': 0.0,
                  'max': 1.0,
                  'value': 0.5,
                  'unit': '',
                },
                {
                  'name': '箱体',
                  'min': 0.0,
                  'max': 1.0,
                  'value': 1.0,
                  'unit': '',
                },
              ]
            : [
                {
                  'name': '驱动',
                  'min': 1.0,
                  'max': 30.0,
                  'value': 12.0,
                  'unit': '',
                },
              ],
      });
    }
    if (command == 'parameter') {
      plugins[arguments['index'] as int]['parameters'][arguments['parameter']
              as int]['value'] =
          arguments['value'];
    }
    if (command == 'move') {
      final first = arguments['index'] as int;
      final second = arguments['destination'] as int;
      final item = plugins.removeAt(first);
      plugins.insert(second, item);
    }
    if (command == 'bypass') {
      plugins[arguments['index'] as int]['bypass'] = arguments['value'];
    }
    if (command == 'remove') plugins.removeAt(arguments['index'] as int);
    return {
      'available': command == 'probe',
      'running': running,
      'plugins': List.of(plugins),
      'gain': gain,
      'sampleRate': 48000,
      'bufferSize': frames,
      'requestedBuffer': frames,
      'backend': 'ALSA',
      'inputLatencyMs': 8.0,
      'outputLatencyMs': 8.0,
      'pluginLatencyMs': 0.0,
      'blockMs': frames / 48.0,
      'cpu': 0.02,
      'xruns': 0,
      'device': 'Test device',
      'inputPeak': 0.25,
      'outputPeak': 0.1,
      'latencyMs': 6,
    };
  }

  @override
  Future<void> dispose() async {
    released = true;
  }
}

void main() {
  testWidgets('四种箱头可添加，窄屏大字号六旋钮独立调参与旁通', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: EffectsPage(backend: backend),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['美式清音箱头', '英式清脆箱头', '英式摇滚箱头', '现代高增益箱头']) {
      final button = find.widgetWithText(OutlinedButton, label);
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(backend.plugins.map((p) => p['kind']), [
      'amp_clean',
      'amp_chime',
      'amp_crunch',
      'amp_modern',
    ]);
    final knob = find.byKey(const ValueKey('0-amp_clean-5'));
    await tester.ensureVisible(knob);
    await tester.pumpAndSettle();
    await tester.ensureVisible(knob);
    await tester.pumpAndSettle();
    await tester.drag(knob, const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.plugins[0]['parameters'][5]['value'], lessThan(1));
    expect(backend.plugins[1]['parameters'][5]['value'], 1);
    final footswitch = find.byKey(const ValueKey('pedal-switch-0'));
    await tester.ensureVisible(footswitch);
    await tester.pumpAndSettle();
    await tester.tap(footswitch);
    await tester.pump();
    expect(backend.plugins[0]['bypass'], isTrue);
    expect(backend.running, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('效果器加载、监听、旁通、停止与离页释放', (tester) async {
    final backend = FakeEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    expect(backend.running, isTrue);
    await tester.scrollUntilVisible(
      find.text('外部 VST3 插件'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('外部 VST3 插件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('外部 VST3 插件'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/tmp/Test.vst3');
    tester.testTextInput.hide();
    await tester.scrollUntilVisible(
      find.text('加载插件'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载插件'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('1. Test Gain'),
      -200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('1. Test Gain'), findsOneWidget);
    expect(backend.calls.where((c) => c == 'start').length, 1);
    expect(backend.calls, isNot(contains('stop')));
    expect(backend.running, isTrue);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pedal-switch-0')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pedal-switch-0')));
    await tester.pump();
    expect(backend.plugins.single['bypass'], isTrue);
    await tester.scrollUntilVisible(
      find.text('停止监听'),
      -200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止监听'));
    await tester.pump();
    expect(backend.running, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(backend.released, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('停止时可调缓冲并显示生效值，监听时禁用缓冲修改', (tester) async {
    final backend = FakeEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    await tester.tap(find.text('停止监听'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('声卡设置与延迟诊断'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('声卡设置与延迟诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('声卡设置与延迟诊断'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('256 帧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('256 帧'));
    await tester.pump();
    expect(backend.frames, 256);
    await tester.scrollUntilVisible(
      find.text('开始监听'),
      -150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始监听'));
    await tester.pump();
    final choices = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    expect(choices.every((choice) => choice.onSelected == null), isTrue);
    await tester.scrollUntilVisible(
      find.textContaining('实际 256 帧'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('每块 5.33 ms'), findsOneWidget);
    expect(find.textContaining('驱动报告：输入 8.0 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('内置效果可重复添加、独立调参、排序和移除', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    expect(backend.running, isTrue);
    for (final label in ['Fuzz 法兹', 'Fuzz 法兹', '延迟']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(backend.plugins.map((p) => p['kind']), ['fuzz', 'fuzz', 'delay']);
    final firstParameter = find.byKey(const ValueKey('0-fuzz-0'));
    await tester.drag(firstParameter, const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      backend.requests.where((r) => r['command'] == 'parameter'),
      isNotEmpty,
    );
    expect(backend.plugins[0]['parameters'][0]['value'], isNot(12.0));
    expect(backend.plugins[1]['parameters'][0]['value'], 12.0);
    await tester.ensureVisible(find.byKey(const ValueKey('pedal-forward-2')));
    await tester.tap(find.byKey(const ValueKey('pedal-forward-2')));
    await tester.pump();
    expect(backend.plugins.map((p) => p['kind']), ['fuzz', 'delay', 'fuzz']);
    await tester.ensureVisible(find.byKey(const ValueKey('pedal-remove-1')));
    await tester.tap(find.byKey(const ValueKey('pedal-remove-1')));
    await tester.pump();
    expect(backend.plugins.map((p) => p['kind']), ['fuzz', 'fuzz']);
    expect(backend.running, isTrue);
    expect(backend.calls, isNot(contains('stop')));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('pedal-remove-0')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('pedal-switch-0')))
          .onPressed,
      isNotNull,
    );
    expect(tester.widget<PedalKnob>(firstParameter).enabled, isTrue);
    await tester.ensureVisible(firstParameter);
    await tester.drag(firstParameter, const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动期间后台停止，恢复不自动重启', (tester) async {
    final ready = Completer<void>();
    final backend = FakeEffects()..starting = ready;
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    ready.complete();
    await tester.pump();
    expect(backend.calls, containsAllInOrder(['start', 'stop']));
    expect(backend.running, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(backend.calls.where((c) => c == 'start'), hasLength(1));
    await tester.tap(find.text('开始监听'));
    await tester.pump();
    expect(backend.running, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(backend.running, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    expect(backend.released, isTrue);
  });

  testWidgets('效果器小屏大字号与失败恢复', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects()..fail = true;
    backend.plugins.add({
      'name': '压缩 Compressor',
      'kind': 'compressor',
      'bypass': false,
      'parameters': [
        for (final name in ['阈值', '压缩比', '启动', '释放', '补偿'])
          {'name': name, 'min': 0.0, 'max': 100.0, 'value': 20.0, 'unit': ''},
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: EffectsPage(backend: backend),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('开始监听'),
      -200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始监听'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.textContaining('测试设备中断'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('测试设备中断'), findsOneWidget);
    backend.fail = false;
    await tester.scrollUntilVisible(
      find.text('开始监听'),
      -150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始监听'));
    await tester.pump();
    expect(backend.running, isTrue);
    expect(find.textContaining('测试设备中断'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('0-compressor-4')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('补偿'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
