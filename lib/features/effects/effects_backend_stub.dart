class EffectsBackend {
  bool get supported => false;
  bool get mobile => false;
  bool get supportsVst3 => false;
  bool get supportsDeviceSettings => false;
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw UnsupportedError('此平台暂不支持实时效果器。');
  Future<void> dispose() async {}
}
