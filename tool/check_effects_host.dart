import 'dart:io';

import 'package:guitarbook/features/effects/effects_backend_native.dart';

// GUITARBOOK_EFFECTS_HOST=/absolute/path/guitarbook_effects_host \
// dart run tool/check_effects_host.dart /absolute/path/TestGain.vst3
Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('需要测试 VST3 插件的绝对路径');
  final backend = EffectsBackend();
  try {
    final initial = await backend.send('status');
    if (initial['running'] != false) throw StateError('引擎不应自动监听');
    try {
      await backend.send('audioBuffer', {'frames': 127});
      throw StateError('应拒绝非法缓冲');
    } on StateError catch (error) {
      if (error.message == '应拒绝非法缓冲') rethrow;
    }
    if ((await backend.send('status'))['audioOpen'] == true) {
      throw StateError('非法请求不应打开音频设备');
    }
    await backend.send('load', {'path': args.single});
    final loaded = await backend.send('bypass', {'index': 0, 'value': true});
    if ((loaded['plugins'] as List).single['bypass'] != true) {
      throw StateError('旁通状态未传回 Flutter');
    }
    try {
      await backend.send('load', {'path': '/missing/invalid.vst3'});
      throw StateError('应拒绝无效插件');
    } on StateError catch (error) {
      if (error.message == '应拒绝无效插件') rethrow;
    }
    final retained = await backend.send('status');
    if ((retained['plugins'] as List).length != 1) {
      throw StateError('加载失败不应清除原效果链');
    }
    await backend.send('editor', {'index': 0});
    final empty = await backend.send('remove', {'index': 0});
    if ((empty['plugins'] as List).isNotEmpty) throw StateError('移除插件失败');
    for (final kind in [
      'compressor',
      'fuzz',
      'overdrive',
      'delay',
      'reverb',
      'delay',
    ]) {
      await backend.send('builtin', {'kind': kind});
    }
    final parameter = await backend.send('parameter', {
      'index': 3,
      'parameter': 0,
      'value': 600,
    });
    final effects = parameter['plugins'] as List;
    if (effects[3]['parameters'][0]['value'] != 600 ||
        effects[5]['parameters'][0]['value'] != 350) {
      throw StateError('重复效果器的参数未独立保存');
    }
    final wet = await backend.send('parameter', {
      'index': 3,
      'parameter': 2,
      'value': 1,
    });
    if ((wet['wetOnly'] as List).length != 1) throw StateError('全湿延迟诊断缺失');
    await backend.send('parameter', {
      'index': 3,
      'parameter': 2,
      'value': 0.25,
    });
    final reordered = await backend.send('move', {
      'index': 3,
      'destination': 4,
    });
    final moved = (reordered['plugins'] as List)[4];
    if (moved['kind'] != 'delay' || moved['parameters'][0]['value'] != 600) {
      throw StateError('排序未保留实例参数');
    }
    await backend.send('load', {'path': args.single});
    final mixed = await backend.send('builtin', {'kind': 'fuzz'});
    if ((mixed['plugins'] as List).length != 8) throw StateError('混合效果链添加失败');
    try {
      await backend.send('builtin', {'kind': 'delay'});
      throw StateError('应拒绝超过八节的效果链');
    } on StateError catch (error) {
      if (error.message == '应拒绝超过八节的效果链') rethrow;
    }
    for (var index = 7; index >= 0; index--) {
      await backend.send('remove', {'index': index});
    }
    await backend.send('stop');
    stdout.writeln(
      'Native host protocol, mixed editable chain and error recovery passed',
    );
  } finally {
    await backend.dispose();
  }
}
