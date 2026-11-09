/// 扫描已安装的 VST2 / VST3 插件后得到的插件信息。
///
/// 字段与原生宿主 `scan` 命令返回的插件条目一一对应：
/// `{format, name, vendor, version, category, path, isInstrument, loadable, note}`。
/// 宿主按 `loadable` 表示当前构建能否真正加载该插件，`note` 给出不可加载的中文原因
/// （例如「当前构建未启用 VST2 加载（需要 Steinberg VST2 SDK）」、「虚拟乐器暂不支持」）。
class ScannedPlugin {
  const ScannedPlugin({
    required this.format,
    required this.name,
    required this.vendor,
    required this.version,
    required this.category,
    required this.path,
    required this.isInstrument,
    required this.loadable,
    required this.note,
  });

  /// 插件格式：`vst3` 或 `vst2`。
  final String format;

  /// 插件名称。
  final String name;

  /// 厂商。
  final String vendor;

  /// 版本号。
  final String version;

  /// 分类（效果器 / 虚拟乐器等）。
  final String category;

  /// 插件文件绝对路径。
  final String path;

  /// 是否是虚拟乐器（虚拟乐器当前不可作为效果器加载）。
  final bool isInstrument;

  /// 当前宿主构建能否真正加载它。
  final bool loadable;

  /// 不可加载时的中文原因；可加载时通常为空。
  final String note;

  /// 从宿主返回的插件条目解析。
  factory ScannedPlugin.fromJson(Map<String, dynamic> json) {
    return ScannedPlugin(
      format: _text(json['format']),
      name: _text(json['name']),
      vendor: _text(json['vendor']),
      version: _text(json['version']),
      category: _text(json['category']),
      path: _text(json['path']),
      isInstrument: json['isInstrument'] == true,
      loadable: json['loadable'] == true,
      note: _text(json['note']),
    );
  }

  /// 格式徽标文字：VST2 / VST3。
  String get formatLabel => switch (format.toLowerCase()) {
    'vst2' => 'VST2',
    'vst3' => 'VST3',
    _ => format.toUpperCase(),
  };

  /// 是否是 VST2 插件。
  bool get isVst2 => format.toLowerCase() == 'vst2';

  /// 是否是 VST3 插件。
  bool get isVst3 => format.toLowerCase() == 'vst3';

  /// 展示用副标题：厂商 · 版本 · 分类（缺失项自动省略）。
  String get subtitle {
    final parts = <String>[
      if (vendor.isNotEmpty) vendor,
      if (version.isNotEmpty) '版本 $version',
      if (category.isNotEmpty) category,
      if (isInstrument && !category.contains('乐器')) '虚拟乐器',
    ];
    return parts.join(' · ');
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';
}

/// 一次扫描的汇总结果，对应宿主 `scan` 命令的响应对象。
///
/// 宿主返回的字段：`platform`、`vst2Supported`、`directories`、`plugins`、
/// `errors`、`durationMs`。
class PluginScanResult {
  const PluginScanResult({
    required this.platform,
    required this.vst2Supported,
    required this.directories,
    required this.plugins,
    required this.errors,
    required this.durationMs,
  });

  /// 扫描所在平台：`windows` / `linux` / `macos`。
  final String platform;

  /// 当前宿主构建是否启用了 VST2 加载。
  final bool vst2Supported;

  /// 实际扫描过的目录。
  final List<String> directories;

  /// 扫描到的插件。
  final List<ScannedPlugin> plugins;

  /// 扫描过程中的问题（目录不可读等）。
  final List<String> errors;

  /// 扫描耗时（毫秒）。
  final int durationMs;

  /// 从宿主返回的扫描对象解析。
  factory PluginScanResult.fromJson(Map<String, dynamic> json) {
    return PluginScanResult(
      platform: json['platform']?.toString().trim() ?? '',
      vst2Supported: json['vst2Supported'] == true,
      directories: _textList(json['directories']),
      plugins: _pluginList(json['plugins']),
      errors: _textList(json['errors']),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// VST3 插件数量。
  int get vst3Count => plugins.where((plugin) => plugin.isVst3).length;

  /// VST2 插件数量。
  int get vst2Count => plugins.where((plugin) => plugin.isVst2).length;

  /// 汇总行：已扫描 N 个目录，发现 X 个插件（VST3 a · VST2 b），耗时 z ms。
  String get summaryLine =>
      '已扫描 ${directories.length} 个目录，发现 ${plugins.length} 个插件'
      '（VST3 $vst3Count · VST2 $vst2Count），耗时 $durationMs ms';

  static List<String> _textList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((Object? item) => item?.toString().trim() ?? '')
        .where((String item) => item.isNotEmpty)
        .toList();
  }

  static List<ScannedPlugin> _pluginList(Object? value) {
    if (value is! List) return const <ScannedPlugin>[];
    final plugins = <ScannedPlugin>[];
    for (final item in value) {
      if (item is Map) {
        plugins.add(
          ScannedPlugin.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    return plugins;
  }
}
