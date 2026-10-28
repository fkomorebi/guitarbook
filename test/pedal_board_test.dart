import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/effects/effects_page.dart';
import 'package:guitarbook/features/effects/pedal_board.dart';

import 'effects_page_test.dart' show FakeEffects;

void main() {
  testWidgets('拖动把手跨多块插入，保留参数旁通，取消不改链', (tester) async {
    tester.view.physicalSize = const Size(1600, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    for (final kind in ['fuzz', 'amp_clean', 'delay', 'fuzz']) {
      await backend.send('builtin', {'kind': kind});
    }
    backend.plugins[0]['parameters'][0]['value'] = 19.0;
    backend.plugins[0]['bypass'] = true;
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pumpAndSettle();
    final source = find.byKey(const ValueKey('pedal-drag-0'));
    final target = find.byKey(const ValueKey('pedal-drag-3'));
    await tester.ensureVisible(source);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.plugins.map((p) => p['kind']), [
      'amp_clean',
      'delay',
      'fuzz',
      'fuzz',
    ]);
    expect(backend.plugins[3]['parameters'][0]['value'], 19);
    expect(backend.plugins[3]['bypass'], isTrue);
    expect(backend.requests.where((r) => r['command'] == 'move').single, {
      'command': 'move',
      'index': 0,
      'destination': 3,
    });
    final cancel = await tester.startGesture(tester.getCenter(target));
    await cancel.moveBy(const Offset(0, -80));
    await tester.pump();
    await cancel.cancel();
    await tester.pumpAndSettle();
    expect(backend.requests.where((r) => r['command'] == 'move'), hasLength(1));
    expect(backend.calls.where((c) => c == 'stop'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('窄屏拖动排序把手至左边缘自动浏览，松开板外不排序', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    for (var i = 0; i < 8; i++) {
      await backend.send('builtin', {'kind': 'fuzz'});
    }
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('pedal-drag-0'));
    await tester.scrollUntilVisible(
      handle,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(handle);
    await tester.pumpAndSettle();
    final start = tester.getCenter(handle);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveTo(Offset(28, start.dy));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getCenter(handle).dx, greaterThan(start.dx));
    await gesture.moveTo(const Offset(0, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c == 'move'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单块右进左出，脚踏旁通与前后排序同步实际音频链', (tester) async {
    tester.view.physicalSize = const Size(1440, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final backend = FakeEffects();
    for (final kind in ['compressor', 'overdrive', 'delay']) {
      await backend.send('builtin', {'kind': kind});
    }
    await tester.pumpWidget(MaterialApp(home: EffectsPage(backend: backend)));
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('pedal-0'));
    final second = find.byKey(const ValueKey('pedal-1'));
    final third = find.byKey(const ValueKey('pedal-2'));
    expect(
      tester.getCenter(first).dx,
      greaterThan(tester.getCenter(second).dx),
    );
    expect(
      tester.getCenter(second).dx,
      greaterThan(tester.getCenter(third).dx),
    );
    expect(
      find.bySemanticsLabel(
        '信号链：吉他输入 → 压缩 Compressor → 过载 Overdrive → 延迟 Delay → 输出（右进左出）',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('pedal-switch-1')));
    await tester.pump();
    expect(backend.plugins[1]['bypass'], isTrue);
    expect(find.byKey(const ValueKey('pedal-led-1-false')), findsOneWidget);
    expect(find.byKey(const ValueKey('pedal-board')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pedal-forward-2')));
    await tester.pump();
    expect(backend.plugins.map((p) => p['kind']), [
      'compressor',
      'delay',
      'overdrive',
    ]);
    expect(
      find.bySemanticsLabel(
        '信号链：吉他输入 → 压缩 Compressor → 延迟 Delay → 过载 Overdrive → 输出（右进左出）',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('pedal-remove-1')));
    await tester.pump();
    expect(
      find.bySemanticsLabel(
        '信号链：吉他输入 → 压缩 Compressor → 过载 Overdrive → 输出（右进左出）',
      ),
      findsOneWidget,
    );
    expect(backend.running, isTrue);
    expect(backend.calls.where((c) => c == 'stop'), isEmpty);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('八块单块可鼠标横拖浏览，窄屏双倍字号与旁通不丢状态', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeEffects();
    for (var i = 0; i < 8; i++) {
      await backend.send('builtin', {'kind': 'delay'});
    }
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
    await tester.pump();
    final mainScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pedal-board')),
      200,
      scrollable: mainScroll,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('0-delay-0')));
    await tester.pumpAndSettle();
    final boardScroll = find.descendant(
      of: find.byType(PedalBoard),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(boardScroll);
    expect(state.position.pixels, lessThan(500));
    final beforeDrag = state.position.pixels;
    expect(state.position.maxScrollExtent, greaterThan(2000));
    // Drag a pedal label horizontally, leaving vertical motion for its knobs.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('0-delay-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(160, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.position.pixels, greaterThan(beforeDrag));
    state.position.jumpTo(state.position.maxScrollExtent);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('pedal-switch-7')));
    await tester.pumpAndSettle();
    final savedOffset = state.position.pixels;
    await tester.tap(find.byKey(const ValueKey('pedal-switch-7')));
    await tester.pump();
    expect(
      tester.state<ScrollableState>(boardScroll).position.pixels,
      savedOffset,
    );
    expect(backend.plugins[7]['bypass'], isTrue);
    expect(backend.plugins[0]['bypass'], isFalse);
    expect(backend.plugins, hasLength(8));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旋钮支持范围限制、精细调节、键盘与无障碍', (tester) async {
    final p = <String, dynamic>{
      'name': '干湿比',
      'min': 0.0,
      'max': 1.0,
      'value': .25,
      'unit': '',
    };
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PedalKnob(
              parameter: p,
              enabled: true,
              onStart: () => starts++,
              onEnd: () => ends++,
              onChanged: (value) => p['value'] = value,
            ),
          ),
        ),
      ),
    );
    final knob = find.byType(PedalKnob);
    await tester.drag(knob, const Offset(0, -240));
    await tester.pump();
    expect(p['value'], 1.0);
    await tester.drag(knob, const Offset(0, 240));
    await tester.pump();
    expect(p['value'], 0.0);
    await tester.tap(knob);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();
    expect(p['value'], greaterThan(0));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final before = p['value'] as double;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(p['value'], greaterThan(before));
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('干湿比'))
          .getSemanticsData()
          .hasAction(SemanticsAction.increase),
      isTrue,
    );
    handle.dispose();
    expect(starts, ends);
    await tester.pumpWidget(const SizedBox());
  });
}
