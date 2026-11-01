import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/expression_pedal_controller.dart';
import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';

import 'support/fake_gamepad_trigger_source.dart';

Future<void> _push(
  FakeGamepadTriggerSource source,
  GamepadSnapshot snapshot,
) async {
  source.push(snapshot);
  await pumpEventQueue();
}

GamepadSnapshot _ready(int raw, {int? min, int? max, String name = 'Xbox 手柄'}) {
  return GamepadSnapshot(
    status: GamepadInputStatus.ready,
    deviceName: name,
    rawValue: raw,
    rawMin: min,
    rawMax: max,
  );
}

void main() {
  test('未启用时不启动输入源，也不读取扳机', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);

    expect(pedal.supported, isTrue);
    expect(pedal.enabled, isFalse);
    expect(source.startCalls, isEmpty);
    expect(pedal.value, 0);
  });

  test('不支持的平台无法启用', () async {
    final source = FakeGamepadTriggerSource()..supported = false;
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);

    await pedal.setEnabled(true);
    expect(pedal.enabled, isFalse);
    expect(source.startCalls, isEmpty);
  });

  test('启用后监听当前扳机并归一化到 0–1', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);

    await pedal.setEnabled(true);
    expect(source.startCalls, [PedalTrigger.right]);

    await _push(source, _ready(128));
    expect(pedal.enabled, isTrue);
    expect(pedal.deviceName, 'Xbox 手柄');
    expect(pedal.rawValue, 128);
    expect(pedal.value, closeTo(128 / 255, 1e-9));
  });

  test('平台报告量程时优先使用平台量程', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    await _push(source, _ready(512, min: 0, max: 1023));
    expect(pedal.minRaw, 0);
    expect(pedal.maxRaw, 1023);
    expect(pedal.value, closeTo(512 / 1023, 1e-9));
  });

  test('手动校准上下限后按校准量程归一化', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    await _push(source, _ready(30));
    expect(pedal.captureMin(), isTrue);
    await _push(source, _ready(980));
    expect(pedal.captureMax(), isTrue);
    expect(pedal.calibrated, isTrue);

    await _push(source, _ready(505));
    expect(pedal.value, closeTo((505 - 30) / (980 - 30), 1e-9));

    pedal.resetCalibration();
    expect(pedal.calibrated, isFalse);
    expect(pedal.minRaw, 0);
    expect(pedal.maxRaw, 255);
  });

  test('没有读数时无法校准', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    expect(pedal.captureMin(), isFalse);
    expect(pedal.captureMax(), isFalse);
  });

  test('记录新下限时丢弃已失效的上限', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    await _push(source, _ready(200));
    expect(pedal.captureMax(), isTrue);
    await _push(source, _ready(250));
    expect(pedal.captureMin(), isTrue);
    expect(pedal.calibrated, isFalse);
    expect(pedal.maxRaw, 255);
  });

  test('反向开关把 0–1 翻转，并立即作用于当前读数', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    await _push(source, _ready(51));
    expect(pedal.value, closeTo(0.2, 1e-9));

    pedal.setInvert(true);
    expect(pedal.invert, isTrue);
    expect(pedal.value, closeTo(0.8, 1e-9));

    await _push(source, _ready(0));
    expect(pedal.value, closeTo(1, 1e-9));
  });

  test('切换扳机会重启输入源并重置位置', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);
    await _push(source, _ready(200));
    expect(pedal.value, greaterThan(0));

    await pedal.setTrigger(PedalTrigger.left);
    expect(pedal.trigger, PedalTrigger.left);
    expect(source.stopCalls, 1);
    expect(source.startCalls, [PedalTrigger.right, PedalTrigger.left]);
    expect(pedal.value, 0);
  });

  test('停用后停止输入源并忽略后续读数', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);
    await _push(source, _ready(100));

    await pedal.setEnabled(false);
    expect(pedal.enabled, isFalse);
    expect(source.stopCalls, 1);
    expect(pedal.status, GamepadInputStatus.searching);

    source.push(_ready(240));
    await pumpEventQueue();
    expect(pedal.rawValue, isNull);
  });

  test('读取流报错时进入错误状态并保留错误说明', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    source.pushError('没有权限读取 /dev/input/event5');
    await pumpEventQueue();
    expect(pedal.status, GamepadInputStatus.error);
    expect(pedal.error, contains('没有权限'));
  });

  test('解析出的位置始终落在 0–1 之间', () async {
    final source = FakeGamepadTriggerSource();
    final pedal = ExpressionPedalController(source: source);
    addTearDown(pedal.dispose);
    await pedal.setEnabled(true);

    await _push(source, _ready(300));
    expect(pedal.value, 1);
    await _push(source, _ready(-10));
    expect(pedal.value, 0);
  });
}
