import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/expression_pedal/gamepad_trigger.dart';
import 'package:guitarbook/features/expression_pedal/web_trigger_logic.dart';

void main() {
  group('标准映射的扳机按钮下标', () {
    test('左扳机是 index 6，右扳机是 index 7', () {
      expect(triggerButtonIndex(PedalTrigger.left), 6);
      expect(triggerButtonIndex(PedalTrigger.right), 7);
      expect(kLeftTriggerButtonIndex, 6);
      expect(kRightTriggerButtonIndex, 7);
    });
  });

  group('扳机模拟量取值', () {
    test('按左右扳机取到对应按钮的模拟量', () {
      final values = List<double>.filled(8, 0);
      values[6] = 0.25;
      values[7] = 0.75;
      expect(
        analogValueFor(
          buttonValues: values,
          trigger: PedalTrigger.left,
        ),
        0.25,
      );
      expect(
        analogValueFor(
          buttonValues: values,
          trigger: PedalTrigger.right,
        ),
        0.75,
      );
    });

    test('按钮数量不足时返回 null', () {
      expect(
        analogValueFor(
          buttonValues: const [0, 0, 0, 0, 0, 0],
          trigger: PedalTrigger.left,
        ),
        isNull,
      );
      expect(
        analogValueFor(
          buttonValues: const [],
          trigger: PedalTrigger.right,
        ),
        isNull,
      );
    });

    test('越界的模拟量会被夹到 0–1', () {
      expect(
        analogValueFor(
          buttonValues: const [-0.5, 0, 0, 0, 0, 0, 0, 2.0],
          trigger: PedalTrigger.left,
        ),
        0.0,
      );
      expect(
        analogValueFor(
          buttonValues: const [-0.5, 0, 0, 0, 0, 0, 0, 2.0],
          trigger: PedalTrigger.right,
        ),
        1.0,
      );
    });

    test('NaN 视为无效读数', () {
      expect(
        analogValueFor(
          buttonValues: const [0, 0, 0, 0, 0, 0, double.nan, 0],
          trigger: PedalTrigger.left,
        ),
        isNull,
      );
    });
  });

  group('原始值换算', () {
    test('0.0–1.0 换算成 0–255 的整数', () {
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0, 0, 0, 0, 0, 0],
          trigger: PedalTrigger.left,
        ),
        0,
      );
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0, 0, 0, 0, 0, 1],
          trigger: PedalTrigger.right,
        ),
        255,
      );
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0, 0, 0, 0, 0, 0.5],
          trigger: PedalTrigger.right,
        ),
        128,
      );
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0, 0, 0, 0, 0.25, 0],
          trigger: PedalTrigger.left,
        ),
        64,
      );
    });

    test('量程与 Windows XInput 版一致', () {
      expect(kWebTriggerRawMin, 0);
      expect(kWebTriggerRawMax, 255);
    });

    test('按钮缺失时没有原始值', () {
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0],
          trigger: PedalTrigger.left,
        ),
        isNull,
      );
    });

    test('超出 0–1 的模拟量不会越界', () {
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0, 0, 0, 0, 5.0, 0],
          trigger: PedalTrigger.left,
        ),
        255,
      );
      expect(
        triggerRawFromButtons(
          buttonValues: const [0, 0, 0, 0, 0, 0, -3.0, 0],
          trigger: PedalTrigger.left,
        ),
        0,
      );
    });
  });

  group('手柄显示名', () {
    test('去掉 Chrome/Edge 的括号说明', () {
      expect(
        gamepadDisplayName('Xbox 360 Controller (XInput STANDARD GAMEPAD)'),
        'Xbox 360 Controller',
      );
      expect(
        gamepadDisplayName('Flydigi Apex 5 (Vendor: 0e6f Product: 0205)'),
        'Flydigi Apex 5',
      );
    });

    test('去掉 Firefox 的 vendor-product- 前缀', () {
      expect(gamepadDisplayName('810-3-USB Gamepad'), 'USB Gamepad');
      expect(gamepadDisplayName('045e-02ea-Xbox 360 Controller'), 'Xbox 360 Controller');
    });

    test('空 id 退化为未知手柄', () {
      expect(gamepadDisplayName(''), '未知手柄');
      expect(gamepadDisplayName('   '), '未知手柄');
      expect(gamepadDisplayName('(Vendor: 0e6f)'), '未知手柄');
    });

    test('过长的名字会被截断', () {
      final name = gamepadDisplayName('${'x' * 80} Pad');
      expect(name.length, lessThanOrEqualTo(41));
      expect(name.endsWith('…'), isTrue);
    });
  });

  group('连接状态记忆', () {
    test('断开后记住断开状态，不会退回通用提示', () {
      final presence = WebGamepadPresence();
      expect(presence.disconnected, isFalse);
      expect(presence.update(found: true, id: 'Flydigi Apex 5'), isTrue);
      expect(presence.disconnected, isFalse);

      expect(presence.update(found: false, id: ''), isTrue);
      expect(presence.disconnected, isTrue);
      expect(presence.deviceId, isNull);

      // 断开后的每一次轮询都应保持断开提示。
      expect(presence.update(found: false, id: ''), isFalse);
      expect(presence.disconnected, isTrue);
    });

    test('重新连上后清除断开状态', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');
      presence.update(found: false, id: '');
      expect(presence.disconnected, isTrue);

      expect(presence.update(found: true, id: 'Flydigi Apex 5'), isTrue);
      expect(presence.disconnected, isFalse);
      expect(presence.deviceId, 'Flydigi Apex 5');
    });

    test('重置后回到“从未连接”的状态', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');
      presence.update(found: false, id: '');
      presence.reset();
      expect(presence.disconnected, isFalse);
      expect(presence.deviceId, isNull);
    });

    test('查找状态的快照区分“从未连接”和“已断开”', () {
      final fresh = searchingSnapshot(disconnected: false);
      expect(fresh.status, GamepadInputStatus.searching);
      expect(fresh.error, contains('按一下手柄'));

      final gone = searchingSnapshot(disconnected: true);
      expect(gone.status, GamepadInputStatus.searching);
      expect(gone.error, contains('手柄已断开'));
    });
  });

  group('找不到手柄时的排查提示', () {
    test('覆盖按按键、Linux 权限和保持前台三种原因', () {
      final hint = searchingSnapshot(disconnected: false).error ?? '';
      expect(hint, contains('按一下手柄'));
      expect(hint, contains('/dev/input/event*'));
      expect(hint, contains('input 组'));
      expect(hint, contains('udev'));
      expect(hint, contains('uaccess'));
      expect(hint, contains('前台'));
    });

    test('提示里不出现内部英文标识', () {
      final hint = searchingSnapshot(disconnected: false).error ?? '';
      expect(hint, isNot(contains('GamepadInputStatus')));
      expect(hint, isNot(contains('rawValue')));
      expect(hint, isNot(contains('button index')));
      expect(hint, isNot(contains('getGamepads')));
      expect(hint, isNot(contains('null')));
    });

    test('没有线性扳机时的说明也不出现内部英文标识', () {
      final message = noAnalogTriggerMessage('Digital Pad');
      expect(message, contains('Digital Pad'));
      expect(message, contains('没有可用的线性扳机'));
      expect(message, isNot(contains('button index')));
      expect(message, isNot(contains('Gamepad')));
    });
  });

  group('浏览器连接事件', () {
    test('连上时立刻重新扫描', () {
      expect(
        webGamepadEventAction(
          event: WebGamepadEvent.connected,
          eventDeviceId: 'Flydigi Apex 5',
          knownDeviceId: null,
        ),
        WebGamepadEventAction.rescan,
      );
    });

    test('断开的正是当前手柄时立刻上报断开', () {
      expect(
        webGamepadEventAction(
          event: WebGamepadEvent.disconnected,
          eventDeviceId: 'Flydigi Apex 5',
          knownDeviceId: 'Flydigi Apex 5',
        ),
        WebGamepadEventAction.rescanAndReportDisconnect,
      );
    });

    test('断开的不是当前手柄时只重新扫描', () {
      expect(
        webGamepadEventAction(
          event: WebGamepadEvent.disconnected,
          eventDeviceId: 'Other Pad',
          knownDeviceId: 'Flydigi Apex 5',
        ),
        WebGamepadEventAction.rescan,
      );
    });

    test('从没连上过的手柄断开时只重新扫描', () {
      expect(
        webGamepadEventAction(
          event: WebGamepadEvent.disconnected,
          eventDeviceId: 'Flydigi Apex 5',
          knownDeviceId: null,
        ),
        WebGamepadEventAction.rescan,
      );
    });

    test('断开事件让状态机记住断开', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');

      expect(
        presence.handleEvent(
          event: WebGamepadEvent.disconnected,
          id: 'Flydigi Apex 5',
        ),
        isTrue,
      );
      expect(presence.disconnected, isTrue);
      expect(presence.deviceId, isNull);
      expect(
        searchingSnapshot(disconnected: presence.disconnected).error,
        contains('手柄已断开'),
      );
    });

    test('断开别的手柄不会影响当前状态', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');

      expect(
        presence.handleEvent(
          event: WebGamepadEvent.disconnected,
          id: 'Other Pad',
        ),
        isFalse,
      );
      expect(presence.disconnected, isFalse);
      expect(presence.deviceId, 'Flydigi Apex 5');
    });

    test('连接事件不改变已知状态，等扫描确认', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');

      expect(
        presence.handleEvent(
          event: WebGamepadEvent.connected,
          id: 'Flydigi Apex 5',
        ),
        isFalse,
      );
      expect(presence.disconnected, isFalse);
      expect(presence.deviceId, 'Flydigi Apex 5');
    });

    test('断开后再连上会清除断开状态', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');
      presence.handleEvent(
        event: WebGamepadEvent.disconnected,
        id: 'Flydigi Apex 5',
      );
      expect(presence.disconnected, isTrue);

      expect(presence.update(found: true, id: 'Flydigi Apex 5'), isTrue);
      expect(presence.disconnected, isFalse);
      expect(
        searchingSnapshot(disconnected: presence.disconnected).error,
        contains('按一下手柄'),
      );
    });
  });

  group('浏览器断开后的残留记录', () {
    test('断开后记住要忽略的设备', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');

      presence.handleEvent(
        event: WebGamepadEvent.disconnected,
        id: 'Flydigi Apex 5',
      );

      // 浏览器断开后可能还在列表里留一条记录，重新连上之前先不用它。
      expect(presence.ignoredId, 'Flydigi Apex 5');
      expect(presence.isIgnored('Flydigi Apex 5'), isTrue);
      expect(presence.isIgnored('Other Pad'), isFalse);
    });

    test('重新连上后不再忽略这条记录', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');
      presence.handleEvent(
        event: WebGamepadEvent.disconnected,
        id: 'Flydigi Apex 5',
      );

      presence.handleEvent(
        event: WebGamepadEvent.connected,
        id: 'Flydigi Apex 5',
      );

      expect(presence.ignoredId, isNull);
      expect(presence.isIgnored('Flydigi Apex 5'), isFalse);
    });

    test('断开别的手柄不会让当前手柄被忽略', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');

      presence.handleEvent(
        event: WebGamepadEvent.disconnected,
        id: 'Other Pad',
      );

      expect(presence.isIgnored('Flydigi Apex 5'), isFalse);
      expect(presence.isIgnored('Other Pad'), isTrue);
      expect(presence.deviceId, 'Flydigi Apex 5');
      expect(presence.disconnected, isFalse);
    });

    test('重置后不再忽略残留记录', () {
      final presence = WebGamepadPresence();
      presence.update(found: true, id: 'Flydigi Apex 5');
      presence.handleEvent(
        event: WebGamepadEvent.disconnected,
        id: 'Flydigi Apex 5',
      );

      presence.reset();

      expect(presence.ignoredId, isNull);
      expect(presence.isIgnored('Flydigi Apex 5'), isFalse);
    });
  });
}
