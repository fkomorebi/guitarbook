import 'pitch_detector.dart';

/// 调音器可选的基准音（A4）。
enum TuningReference {
  /// 国际标准基准：A4 = 440 Hz。
  standard(a4: 440.0, label: 'A4 = 440 Hz', description: '国际标准基准 · 目标频率与常规一致'),

  /// 自然音准：A4 = 432 Hz，全部目标频率比标准低约 31.8 音分。
  natural(
    a4: 432.0,
    label: 'A4 = 432 Hz',
    description: '自然音准 · 全部目标频率比 440 Hz 低约 31.8 音分',
  );

  const TuningReference({
    required this.a4,
    required this.label,
    required this.description,
  });

  /// A4 基准频率（Hz）。
  final double a4;

  /// 分段选项短标题。
  final String label;

  /// 模式说明文案。
  final String description;

  /// 相对 440 Hz 基准的缩放系数。
  ///
  /// guitarStrings 固定以 440 Hz 为准，切换基准只在这里整体缩放，
  /// 避免改动既有音高表而影响依赖 440 Hz 的其他逻辑。
  double get scale => a4 / 440.0;

  /// 当前基准下第 index 根空弦（0 = 六弦 E2）的目标频率。
  double stringFrequency(int index) => guitarStrings[index].frequency * scale;

  /// 当前基准下六根空弦的目标频率列表（label 沿用 guitarStrings）。
  List<({String label, double frequency})> get strings => [
    for (final string in guitarStrings)
      (label: string.label, frequency: string.frequency * scale),
  ];
}
