import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/app/brand.dart';
import 'package:guitarbook/app/guitarbook_app.dart';

void main() {
  test('品牌与工具插画都已打包进资源清单', () async {
    const assets = [
      AppAssets.heroHome,
      AppAssets.logo,
      AppAssets.tuner,
      AppAssets.metronome,
      AppAssets.chords,
      AppAssets.scales,
      AppAssets.jam,
      AppAssets.effects,
      AppAssets.band,
    ];
    for (final asset in assets) {
      final data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: '$asset 内容为空');
    }
  });

  testWidgets('首页展示品牌标志、插画横幅与工具插画', (tester) async {
    await tester.pumpWidget(const GuitarbookApp());
    await tester.pumpAndSettle();

    expect(find.byType(BrandMark), findsOneWidget);
    expect(find.byType(ToolIllustration), findsWidgets);
    expect(find.text('每一次拨弦，\n都更进一步。'), findsOneWidget);
    expect(find.text('调准琴弦，找到节奏，开始今天的练习。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('插画在窄屏与宽屏都使用同一份资源', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final size in [const Size(320, 568), const Size(1440, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const GuitarbookApp());
      await tester.pumpAndSettle();

      final images = tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image as AssetImage)
          .toList();
      final paths = images.map((image) => image.assetName).toSet();
      expect(paths, contains(AppAssets.heroHome));
      expect(paths, contains(AppAssets.logo));
      expect(paths, contains(AppAssets.tuner));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
