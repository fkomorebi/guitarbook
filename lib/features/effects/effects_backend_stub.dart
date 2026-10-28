class EffectsBackend {
  bool get supported => false;
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw UnsupportedError('实时效果器目前仅支持 Linux 和 Windows。');
  Future<void> dispose() async {}
}
