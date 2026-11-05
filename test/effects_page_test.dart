import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/effects/effects_backend.dart';
import 'package:guitarbook/features/effects/effects_page.dart';
import 'package:guitarbook/features/effects/pedal_board.dart';
import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';

import 'support/fake_gamepad_trigger_source.dart';

class FakeEffects extends EffectsBackend {
  final calls = <String>[];
  final requests = <Map<String, dynamic>>[];
  bool running = false;
  bool released = false;
  bool fail = false;
  bool noInputSignal = false;
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
          'wah': '哇音 Wah',
          'fuzz': 'Fuzz 法兹',
          'compressor': '压缩 Compressor',
          'reverb': '混响 Reverb',
          'overdrive': '过载 Overdrive',
          'delay': '延迟 Delay',
          'amp_clean': '美式清音箱头',
          'amp_chime': '英式清脆箱头',
          'amp_crunch': '英式摇滚箱头',
          'amp_modern': '现代高增益箱头',
          'pitch': '移调 Pitch',
        }[kind],
        'kind': kind,
        'bypass': false,
        'parameters': kind == 'wah'
            ? [
                for (final item in [
                  ('位置', 0.0, 1.0, 0.5, ''),
                  ('共振', 0.5, 8.0, 2.0, 'Q'),
                  ('干湿比', 0.0, 1.0, 1.0, ''),
                  ('输出', 0.0, 1.0, 0.7, ''),
                  ('自动', 0.0, 1.0, 0.0, ''),
                  ('速度', 0.1, 5.0, 1.0, 'Hz'),
                  ('深度', 0.0, 1.0, 0.8, ''),
                ])
                  {
                    'name': item.$1,
                    'min': item.$2,
                    'max': item.$3,
                    'value': item.$4,
                    'unit': item.$5,
                  },
              ]
            : kind.startsWith('amp_')
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
            : kind == 'pitch'
            ? [
                {
                  'name': '移调',
                  'min': -12.0,
                  'max': 12.0,
                  'value': 0.0,
                  'unit': '半音',
                },
                {
                  'name': '干湿比',
                  'min': 0.0,
                  'max': 1.0,
                  'value': 1.0,
                  'unit': '',
                },
                {
                  'name': '输出',
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
      'noInputSignal': noInputSignal,
    };
  }

  @override
  Future<void> dispose() async {
    released = true;
  }
}

class MobileEffects extends FakeEffects {
  @override
  bool get mobile => true;
  @override
  bool get supportsVst3 => false;
  @override
  bool get supportsDeviceSettings => false;
  @override
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async => {
    ...await super.send(command, arguments),
    'latencyAvailable': false,
    'cpuAvailable': false,
    'outputBufferFrames': 192,
  };
}

class FakeWebEffects extends FakeEffects {
  int captureSampleRate = 48000;
  double captureLatencyMs = 21.3;
  String capturePath = 'MediaStreamTrackProcessor';

  @override
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async => {
    ...await super.send(command, arguments),
    'backend': 'Web Audio (AudioWorklet)',
    'device': '浏览器音频设备',
    'inputChannels': 1,
    'outputChannels': 2,
    'latencyScope': 'output-only',
    'baseLatencyMs': 10.7,
    'outputLatencyMs': 54.0,
    'latencyMs': 64.7,
    'latencyAvailable': true,
    'captureSampleRate': captureSampleRate,
    'captureLatencyMs': captureLatencyMs,
    'capturePath': capturePath,
    'cpuAvailable': false,
  };
}

/// 把效果器页滚动到能看见 [finder] 的位置。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('自动哇音在窄屏双倍字号可调节深度', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await backend.send('builtin', {'kind': 'wah'});
    backend.plugins[0]['parameters'][4]['value'] = 1.0;
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
    await tester.pumpAndSettle();
    final depth = find.byKey(const ValueKey('0-wah-6'));
    await tester.scrollUntilVisible(
      depth,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(depth);
    await tester.pumpAndSettle();
    await tester.drag(depth, const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.plugins[0]['parameters'][6]['value'], lessThan(0.8));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('哇音可重复添加，位置独立调节与旁通', (tester) async {
    final backend = FakeEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final button = find.widgetWithText(OutlinedButton, '哇音 Wah');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(backend.plugins.map((p) => p['kind']), ['wah', 'wah']);
    final position = find.byKey(const ValueKey('0-wah-0'));
    await tester.ensureVisible(position);
    await tester.pumpAndSettle();
    await tester.drag(position, const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.plugins[0]['parameters'][0]['value'], greaterThan(0.5));
    expect(backend.plugins[1]['parameters'][0]['value'], 0.5);
    final mode = find.byKey(const ValueKey('wah-mode-0'));
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(backend.plugins[0]['parameters'][4]['value'], 1);
    expect(backend.plugins[1]['parameters'][4]['value'], 0);
    expect(find.byKey(const ValueKey('0-wah-5')), findsOneWidget);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(backend.plugins[0]['parameters'][4]['value'], 0);
    expect(find.byKey(const ValueKey('0-wah-5')), findsNothing);
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

  testWidgets(
    'mobile keeps builtins and wet workbench, hides desktop controls',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = MobileEffects();
      await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
      await tester.pumpAndSettle();
      expect(backend.calls.first, 'start');
      expect(find.text('声卡与输入通道'), findsNothing);
      expect(find.text('外部 VST3 插件'), findsNothing);
      await tester.scrollUntilVisible(find.text('美式清音箱头'), 200);
      await tester.ensureVisible(find.text('美式清音箱头'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('美式清音箱头'));
      await tester.pumpAndSettle();
      expect(backend.plugins.single['kind'], 'amp_clean');
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('声卡设置与延迟诊断'));
      await tester.tap(find.text('声卡设置与延迟诊断'));
      await tester.pumpAndSettle();
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.textContaining('不提供可靠的驱动延迟报告'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(backend.released, true);
    },
  );

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

  testWidgets('网页后端说明缓冲不可调，并区分输出侧报告与实测往返延迟', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = FakeWebEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    expect(find.textContaining('输出侧延迟 64.7 ms'), findsOneWidget);

    await _scrollTo(tester, find.text('声卡设置与延迟诊断'));
    await tester.tap(find.text('声卡设置与延迟诊断'));
    await tester.pumpAndSettle();
    expect(find.text('64 帧'), findsNothing);
    expect(find.text('256 帧'), findsNothing);
    await _scrollTo(tester, find.textContaining('网页端监听缓冲由浏览器'));
    await _scrollTo(tester, find.textContaining('图内缓冲 10.7 ms'));
    expect(find.textContaining('+ 设备输出 54.0 ms = 64.7 ms'), findsOneWidget);
    await _scrollTo(tester, find.textContaining('浏览器上报采集缓冲：21.3 ms'));
    expect(find.textContaining('浏览器可见部分合计：86.0 ms'), findsOneWidget);
    expect(find.textContaining('采集链路：低延迟插入式流'), findsOneWidget);
    expect(find.textContaining('驱动报告'), findsNothing);
    expect(find.textContaining('报告合计'), findsNothing);
    expect(find.textContaining('报告延迟偏高'), findsNothing);
    await _scrollTo(tester, find.textContaining('继续降低延迟'));
    expect(find.textContaining('--audio-buffer-size=128'), findsOneWidget);
    expect(find.textContaining('guitarbook_effects_host'), findsOneWidget);
    expect(find.textContaining('PipeWire quantum'), findsOneWidget);
    expect(find.textContaining('采集 48000 Hz'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网页端浏览器没给采集缓冲读数时说明只能靠系统侧测量', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = FakeWebEffects()..captureLatencyMs = 0;
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    await _scrollTo(tester, find.text('声卡设置与延迟诊断'));
    await tester.tap(find.text('声卡设置与延迟诊断'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.textContaining('浏览器只提供输出侧读数'));
    expect(find.textContaining('浏览器只提供输出侧读数'), findsOneWidget);
    expect(find.textContaining('浏览器上报采集缓冲'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网页端采集链路回退到兼容路径时说明原因', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeWebEffects()
      ..capturePath = 'MediaStreamAudioSourceNode';
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    await _scrollTo(tester, find.text('声卡设置与延迟诊断'));
    await tester.tap(find.text('声卡设置与延迟诊断'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.textContaining('采集链路：兼容路径'));
    expect(find.textContaining('采集链路：兼容路径'), findsOneWidget);
    expect(find.textContaining('采集链路：低延迟插入式流'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('网页采集与上下文采样率不一致时提示重采样', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = FakeWebEffects()..captureSampleRate = 44100;
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    await _scrollTo(tester, find.text('声卡设置与延迟诊断'));
    await tester.tap(find.text('声卡设置与延迟诊断'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.textContaining('采集 44100 Hz'));
    expect(find.textContaining('采集 44100 Hz 与上下文 48000 Hz'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('监听中只有数字静音时提示输入设备可能不是吉他接口', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final backend = FakeEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    expect(backend.running, isTrue);
    expect(find.text('没有收到任何输入数据。'), findsNothing);

    backend.noInputSignal = true;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('没有收到任何输入数据。'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('没有收到任何输入数据。'), findsOneWidget);
    expect(find.textContaining('回环通道'), findsOneWidget);
    expect(find.text('重新连接设备'), findsOneWidget);
    expect(find.text('声卡与输入通道'), findsWidgets);

    backend.noInputSignal = false;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('没有收到任何输入数据。'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(backend.released, isTrue);
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

  testWidgets('移调效果可添加，三个旋钮独立调参并显示半音单位', (tester) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pump();
    final button = find.widgetWithText(OutlinedButton, '移调');
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
    expect(backend.plugins.map((p) => p['kind']), ['pitch']);
    final semitone = find.byKey(const ValueKey('0-pitch-0'));
    await tester.ensureVisible(semitone);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('0-pitch-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('0-pitch-2')), findsOneWidget);
    await tester.drag(semitone, const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 100));
    final value = backend.plugins[0]['parameters'][0]['value'] as double;
    expect(value, greaterThan(0));
    expect(value, lessThanOrEqualTo(12));
    expect(backend.plugins[0]['parameters'][1]['value'], 1.0);
    expect(backend.plugins[0]['parameters'][2]['value'], 1.0);
    expect(find.text('PITCH'), findsOneWidget);
    expect(find.textContaining('半音'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('启动期间后台停止，回到前台自动恢复监听', (tester) async {
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
    await tester.pump();
    // 最小化窗口会释放声卡，回到前台后自动恢复监听。
    expect(backend.calls.where((c) => c == 'start'), hasLength(2));
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

  testWidgets('手柄扳机可以连续驱动哇音位置', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await backend.send('builtin', {'kind': 'wah'});
    final source = FakeGamepadTriggerSource();
    await tester.pumpWidget(
      MaterialApp(
        home: EffectsPage(backend: backend, pedalSource: source),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('expression-pedal-enabled'));
    await _scrollTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(source.startCalls, [PedalTrigger.right]);
    expect(find.textContaining('正在查找手柄'), findsOneWidget);

    source.push(
      const GamepadSnapshot(
        status: GamepadInputStatus.ready,
        deviceName: 'Xbox 手柄',
        rawValue: 0,
        rawMin: 0,
        rawMax: 255,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('已连接：Xbox 手柄'), findsOneWidget);

    source.push(
      const GamepadSnapshot(
        status: GamepadInputStatus.ready,
        deviceName: 'Xbox 手柄',
        rawValue: 204,
        rawMin: 0,
        rawMax: 255,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    final parameterRequests = backend.requests
        .where((request) => request['command'] == 'parameter')
        .toList();
    expect(parameterRequests, isNotEmpty);
    expect(parameterRequests.last['index'], 0);
    expect(parameterRequests.last['parameter'], 0);
    expect(parameterRequests.last['value'] as double, closeTo(0.8, 0.01));
    expect(
      backend.plugins[0]['parameters'][0]['value'] as double,
      closeTo(0.8, 0.01),
    );
    final valueText = tester.widget<Text>(
      find.byKey(const ValueKey('expression-pedal-value')),
    );
    expect(valueText.data, '80%');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(source.disposeCalls, 1);
  });

  testWidgets('目标哇音处于自动模式时不写入位置', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await backend.send('builtin', {'kind': 'wah'});
    backend.plugins[0]['parameters'][4]['value'] = 1.0;
    final source = FakeGamepadTriggerSource();
    await tester.pumpWidget(
      MaterialApp(
        home: EffectsPage(backend: backend, pedalSource: source),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('expression-pedal-enabled'));
    await _scrollTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    source.push(
      const GamepadSnapshot(
        status: GamepadInputStatus.ready,
        deviceName: 'Xbox 手柄',
        rawValue: 200,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    expect(
      backend.requests.where((request) => request['command'] == 'parameter'),
      isEmpty,
    );
    expect(find.textContaining('自动扫频模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('没有哇音时启用手柄踏板也不写入效果链', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    final source = FakeGamepadTriggerSource();
    await tester.pumpWidget(
      MaterialApp(
        home: EffectsPage(backend: backend, pedalSource: source),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('expression-pedal-enabled'));
    await _scrollTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.textContaining('先在效果链中添加'), findsOneWidget);
    source.push(
      const GamepadSnapshot(
        status: GamepadInputStatus.ready,
        deviceName: 'Xbox 手柄',
        rawValue: 120,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    expect(
      backend.requests.where((request) => request['command'] == 'parameter'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('不支持的平台只显示说明，不显示启用开关', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    final source = FakeGamepadTriggerSource()..supported = false;
    await tester.pumpWidget(
      MaterialApp(
        home: EffectsPage(backend: backend, pedalSource: source),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('手柄线性扳机 → 哇音踏板'));

    expect(
      find.byKey(const ValueKey('expression-pedal-enabled')),
      findsNothing,
    );
    expect(find.textContaining('不支持读取手柄'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手柄踏板在窄屏双倍字号下可操作且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await backend.send('builtin', {'kind': 'wah'});
    final source = FakeGamepadTriggerSource();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: EffectsPage(backend: backend, pedalSource: source),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('expression-pedal-enabled'));
    await _scrollTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    source.push(
      const GamepadSnapshot(
        status: GamepadInputStatus.ready,
        deviceName: 'Xbox 手柄',
        rawValue: 128,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final trigger = find.byKey(const ValueKey('expression-pedal-trigger'));
    await _scrollTo(tester, trigger);
    expect(trigger, findsOneWidget);
    final calibrate = find.byKey(
      const ValueKey('expression-pedal-calibrate-min'),
    );
    await _scrollTo(tester, calibrate);
    expect(calibrate, findsOneWidget);
    expect(
      find.byKey(const ValueKey('expression-pedal-value')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未启用时不显示“正在查找手柄”，启用后才开始查找', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    await backend.send('builtin', {'kind': 'wah'});
    final source = FakeGamepadTriggerSource();
    await tester.pumpWidget(
      MaterialApp(
        home: EffectsPage(backend: backend, pedalSource: source),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('手柄线性扳机 → 哇音踏板'));
    expect(find.textContaining('未启用'), findsOneWidget);
    expect(find.textContaining('正在查找手柄'), findsNothing);
    expect(source.startCalls, isEmpty);

    final toggle = find.byKey(const ValueKey('expression-pedal-enabled'));
    await _scrollTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(source.startCalls, [PedalTrigger.right]);
    expect(find.textContaining('正在查找手柄'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
