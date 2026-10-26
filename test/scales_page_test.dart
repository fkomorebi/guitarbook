import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/scales/scales_page.dart';
import 'package:guitarbook/features/scales/scale_pattern.dart';
import 'package:guitarbook/features/scales/scale_guide.dart';

void main() {
  testWidgets('intro and explanation follow every selected scale and key', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ScalesPage()));
    expect(find.text('先认识音阶'), findsOneWidget);
    for (var i = 0; i < scaleTypes.length; i++) {
      final selector = tester.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>).at(1),
      );
      selector.onChanged!(i);
      await tester.pumpAndSettle();
      final guide = scaleGuides[scaleTypes[i].name]!;
      expect(find.text('结构特点：${guide.character}'), findsOneWidget);
      expect(find.text('听感与用途：${guide.sound}'), findsOneWidget);
      expect(find.text('怎么练：${guide.practice}'), findsOneWidget);
    }
    tester
        .widget<DropdownButtonFormField<int>>(
          find.byType(DropdownButtonFormField<int>).first,
        )
        .onChanged!(9);
    await tester.pumpAndSettle();
    expect(find.text('A · 洛克里亚'), findsOneWidget);
    expect(find.textContaining('先找根音 A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'only scale tones across the fretboard are labelled and horizontal dragging works',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ScalesPage()));
      final board = find.byKey(const ValueKey('fretboard-scroll'));
      final view = tester.widget<SingleChildScrollView>(board);
      // All C major tones across the board are shown, including outside the selected position.
      final expected = [
        for (final open in openStrings)
          for (var fret = 0; fret <= 22; fret++)
            if (scaleTypes.first.intervals.contains((open + fret) % 12)) fret,
      ].length;
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics && (w.properties.label?.contains('弦 ') ?? false),
        ),
        findsNWidgets(expected),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == '6弦 1品 F',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              (w.properties.label?.startsWith('6弦 2品 ') ?? false),
        ),
        findsNothing,
      );
      await tester.ensureVisible(board);
      await tester.pumpAndSettle();
      expect(view.controller!.offset, 0);
      final rect = tester.getRect(board);
      final start = Offset(rect.right - 80, rect.top + 100);
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(-300, 0));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(view.controller!.offset, greaterThan(0));
      view.controller!.jumpTo(0);
      await tester.pump();
      final touch = await tester.startGesture(start);
      await touch.moveBy(const Offset(-30, 0));
      await touch.moveBy(const Offset(-270, 0));
      await touch.up();
      await tester.pumpAndSettle();
      expect(view.controller!.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('scale systems switch on small screens with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const ScalesPage(),
        ),
      ),
    );
    expect(find.text('E 形把位'), findsOneWidget);
    await tester.ensureVisible(find.text('一弦三音系统'));
    await tester.tap(find.text('一弦三音系统'));
    await tester.pumpAndSettle();
    expect(find.text('把位 7 · 7 级起'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('CAGED 系统'));
    await tester.tap(find.text('CAGED 系统'));
    await tester.pumpAndSettle();
    expect(find.text('G 形把位'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
