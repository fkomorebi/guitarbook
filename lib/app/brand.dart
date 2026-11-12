import 'package:flutter/material.dart';

/// 应用内的插画与标志资源。
///
/// 这些图片由本机 ComfyUI 按 `tool/assets.json` 的提示词生成，
/// 再由 `tool/build_assets.js` 压缩为 WebP，见 `docs/FEATURES.md` 的「视觉素材」一节。
abstract final class AppAssets {
  static const String heroHome = 'assets/images/hero_home.webp';
  static const String logo = 'assets/images/logo_app.webp';
  static const String tuner = 'assets/images/tool_tuner.webp';
  static const String metronome = 'assets/images/tool_metronome.webp';
  static const String chords = 'assets/images/tool_chords.webp';
  static const String scales = 'assets/images/tool_scales.webp';
  static const String jam = 'assets/images/tool_jam.webp';
  static const String effects = 'assets/images/tool_effects.webp';
  static const String band = 'assets/images/tool_band.webp';
}

/// 应用标志：圆形裁切的小图，用于标题栏与品牌位置。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32, this.semanticLabel});

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Image.asset(
        AppAssets.logo,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        semanticLabel: semanticLabel,
      ),
    );
  }
}

/// 工具插画：圆角方图，用于工具卡片与面板标题。
class ToolIllustration extends StatelessWidget {
  const ToolIllustration({
    super.key,
    required this.asset,
    this.size = 56,
    this.radius = 14,
    this.semanticLabel,
  });

  final String asset;
  final double size;
  final double radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
