import 'dart:convert';

import 'package:flutter/services.dart';

/// One native session per backend: a late disposal cannot stop a new page.
class EffectsMobileTransport {
  EffectsMobileTransport({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('guitarbook/effects');

  static int _nextSession = 0;
  final String _session =
      '${DateTime.now().microsecondsSinceEpoch}-${++_nextSession}';
  final MethodChannel _channel;
  bool _disposed = false;

  Future<Map<String, dynamic>> send(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    if (_disposed) throw StateError('效果器已关闭。');
    final response = await _channel.invokeMethod<String>('command', {
      ...arguments,
      'session': _session,
      'command': command,
    });
    if (_disposed) throw StateError('效果器已关闭。');
    final envelope = jsonDecode(response!) as Map<String, dynamic>;
    if (envelope['error'] != null) {
      throw StateError(envelope['error'].toString());
    }
    return Map<String, dynamic>.from(envelope['result'] as Map);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('dispose', {'session': _session});
  }
}
