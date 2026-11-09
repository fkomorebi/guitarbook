class EffectsBackend {
  bool get supported => false;
  bool get mobile => false;
  bool get supportsVst3 => false;
  bool get supportsDeviceSettings => false;

  /// 此平台暂不支持实时效果器，也就无法扫描 VST 插件。
  bool get supportsPluginScan => false;
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw UnsupportedError('此平台暂不支持实时效果器。');
  Future<void> dispose() async {}
}
