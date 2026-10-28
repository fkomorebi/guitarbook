import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/effects/effects_mobile_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('guitarbook/effects');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'mobile commands retain native session and surface DSP errors',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'dispose') return null;
        if ((call.arguments as Map)['command'] == 'load') {
          return jsonEncode({'error': '移动端仅支持内置效果器'});
        }
        return jsonEncode({
          'result': {'running': true, 'plugins': []},
        });
      });
      final backend = EffectsMobileTransport();
      expect((await backend.send('start', {}))['running'], true);
      await backend.send('builtin', {'kind': 'amp_clean'});
      expect((calls.last.arguments as Map)['kind'], 'amp_clean');
      expect(
        (calls.first.arguments as Map)['session'],
        (calls.last.arguments as Map)['session'],
      );
      await expectLater(backend.send('load', {}), throwsStateError);
      await backend.dispose();
      await backend.dispose();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      await expectLater(backend.send('status', {}), throwsStateError);
    },
  );

  test(
    'late disposal and in-flight responses cannot affect a new session',
    () async {
      final response = Completer<String>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'dispose') return null;
        return response.future;
      });
      final first = EffectsMobileTransport();
      final second = EffectsMobileTransport();
      final pending = first.send('start', {});
      await Future<void>.delayed(Duration.zero);
      final rejected = expectLater(pending, throwsStateError);
      await first.dispose();
      response.complete(
        jsonEncode({
          'result': {'running': true},
        }),
      );
      await rejected;
      await second.send('start', {});
      final firstSession = (calls.first.arguments as Map)['session'];
      expect((calls[1].arguments as Map)['session'], firstSession);
      expect((calls.last.arguments as Map)['session'], isNot(firstSession));
      await second.dispose();
    },
  );

  test('permission and platform errors reach the caller for retry', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'permission', message: '需要录音权限');
    });
    final backend = EffectsMobileTransport();
    await expectLater(
      backend.send('start', {}),
      throwsA(isA<PlatformException>()),
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => jsonEncode({
        'result': {'running': true},
      }),
    );
    expect((await backend.send('start', {}))['running'], true);
  });
}
