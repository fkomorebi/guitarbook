import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'effects_capture_mstp_web.dart';

/// 电脑端浏览器的实时效果器后端。
///
/// 音频链路（Web Audio API + AudioWorklet）：
/// `getUserMedia` → `MediaStreamAudioSourceNode` →
/// `AudioWorkletNode('guitarbook-effects')` → `AudioContext.destination`。
/// DSP 全部跑在 `web/effects_worklet.js` 里，主线程只负责命令转发与状态汇报。
///
/// 与原生宿主保持一致的部分：效果链最多 8 块、内置效果参数定义与顺序、
/// 参数夹取到量程、错误文案风格、`status` 字段结构。
///
/// 网页端特有约束：
/// - 不支持 VST3、声卡/输入通道设置与湿声 Looper；
/// - 延迟由浏览器 I/O 缓冲决定：只有输出侧（`baseLatency` + `outputLatency`）
///   有读数，采集缓冲由浏览器与系统音频栈控制，页面读不到，往返延迟需环回实测；
/// - 首次启动必须由用户手势触发（浏览器自动播放策略）。
class EffectsBackend {
  /// 效果链最多 8 块（与原生宿主一致）。
  static const int _maxEffects = 8;

  /// AudioWorklet 的渲染量子固定为 128 帧。
  static const int _renderQuantum = 128;

  /// worklet 模块路径：相对页面 base href，Flutter Web 构建后会发布在根目录。
  static const String _workletModule = 'effects_worklet.js';

  /// worklet 处理器注册名。
  static const String _processorName = 'guitarbook-effects';

  static const String _backendName = 'Web Audio (AudioWorklet)';

  /// 采集链路名称（写入 `status` 的 `capturePath`）。
  static const String _capturePathMstp = 'MediaStreamTrackProcessor';
  static const String _capturePathSourceNode = 'MediaStreamAudioSourceNode';

  static const String _gestureNotice =
      '浏览器要求用户手势：请再点击一次「开始监听」。';
  static const String _micDeniedNotice =
      '浏览器未授权麦克风：请在地址栏允许麦克风后重试。';
  static const String _secureContextNotice =
      '需要 HTTPS 或 localhost 才能访问麦克风。';
  static const String _mobileNotice = '仅电脑端浏览器支持实时效果器。';

  /// AudioWorklet 输出固定为双声道（单声道麦克风输入自动上混）。
  static final JSArray<JSNumber> _stereoChannels = <JSNumber>[2.0.toJS].toJS;

  final List<_EffectSlot> _chain = <_EffectSlot>[];

  web.AudioContext? _context;
  web.AudioWorkletNode? _node;
  web.MediaStreamAudioSourceNode? _source;
  web.MediaStream? _stream;
  bool _workletReady = false;
  bool _disposed = false;
  bool _running = false;
  bool _failed = false;
  double _gain = 0.5;
  double _inputPeak = 0;
  double _outputPeak = 0;
  String? _notice;
  String? _workletError;
  String? _inputDevice;

  /// 采集轨道的实际设置：用于判断浏览器采集侧是否发生了重采样。
  int? _captureSampleRate;
  int? _captureChannels;

  /// 浏览器上报的采集缓冲（秒→毫秒）：只含设备采集侧，不含浏览器内部队列。
  double? _captureLatencyMs;

  /// 当前采集链路：`MediaStreamTrackProcessor`（低延迟）或 `MediaStreamAudioSourceNode`。
  String _capturePath = 'none';

  /// 低延迟采集实例；为空表示当前走的是 source node 路径。
  MstpCapture? _mstp;

  /// 网页端不是移动端适配层。
  bool get mobile => false;

  /// 仅电脑端浏览器支持；移动端浏览器不支持。
  bool get supported => !_isMobileBrowser;

  /// 网页端不支持 VST3。
  bool get supportsVst3 => false;

  /// 网页端不支持声卡与输入通道设置。
  bool get supportsDeviceSettings => false;

  bool get _isMobileBrowser {
    final agent = web.window.navigator.userAgent.toLowerCase();
    return agent.contains('android') ||
        agent.contains('iphone') ||
        agent.contains('ipad') ||
        agent.contains('mobile');
  }

  /// 向宿主发送命令并返回完整状态。
  ///
  /// 命令语义与原生宿主一致：`probe` / `start` / `stop` / `status` /
  /// `builtin` / `parameter` / `remove` / `bypass` / `move` / `gain` /
  /// `audioBuffer`。
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (_disposed) throw StateError('效果器已关闭。');
    switch (command) {
      case 'probe':
        return _probe();
      case 'start':
        return _start();
      case 'stop':
        return _stop();
      case 'status':
        return _status();
      case 'builtin':
        return _addBuiltin(arguments);
      case 'parameter':
        return _setParameter(arguments);
      case 'remove':
        return _remove(arguments);
      case 'bypass':
        return _setBypass(arguments);
      case 'move':
        return _move(arguments);
      case 'gain':
        return _setGain(arguments);
      case 'audioBuffer':
        return _audioBuffer(arguments);
      case 'settings':
        throw UnsupportedError('网页端不支持声卡设置（输入设备由浏览器与系统决定）。');
      case 'load':
        throw UnsupportedError('网页端不支持 VST3 插件。');
      case 'editor':
        throw UnsupportedError('网页端不支持插件参数窗口（请直接在踏板板上调节参数）。');
      case 'loopStart':
      case 'loopStop':
      case 'loopRead':
        throw UnsupportedError(
          '网页端效果器暂不支持湿声 Looper（请使用原生端或桌面版）。',
        );
      default:
        throw StateError('未知宿主命令。');
    }
  }

  /// 探测音频输入设备（不申请麦克风权限）。
  Future<Map<String, dynamic>> _probe() async {
    _notice = null;
    var available = false;
    String? label;
    try {
      final devices =
          await web.window.navigator.mediaDevices.enumerateDevices().toDart;
      for (final device in devices.toDart) {
        if (device.kind != 'audioinput') continue;
        available = true;
        final text = device.label.trim();
        if (text.isNotEmpty) {
          label = text;
          break;
        }
      }
    } catch (error) {
      _notice = '无法枚举音频输入设备：$error';
    }
    if (available) {
      _notice ??= '已检测到音频输入设备，点击「开始监听」并允许麦克风后即可出声。';
      if (label != null) _inputDevice ??= label;
    } else {
      _notice ??= '未检测到音频输入设备：请连接声卡或麦克风，并在地址栏允许使用麦克风。';
    }
    final status = _status();
    status['available'] = available;
    return status;
  }

  /// 建立音频链路并开始监听。
  ///
  /// 浏览器自动播放策略要求上下文在用户手势里 `resume()`；若当前没有用户
  /// 激活（页面刚打开），只创建上下文并给出明确提示，由用户点击「开始监听」
  /// 后再真正出声。
  Future<Map<String, dynamic>> _start() async {
    if (!supported) {
      throw _WebEffectsException(_mobileNotice);
    }
    final activation = _userActivation();
    // 数字 0 让 Chrome 取最小内部缓冲；本机环回实测比 'interactive'
    // 少 8 ms 端到端（baseLatency 10.7 → 2.7 ms）。不支持数字提示的
    // 浏览器（Firefox / Safari）会忽略它，行为与不传一致。
    final context = _context ??= web.AudioContext(
      web.AudioContextOptions(latencyHint: 0.toJS),
    );
    if (!activation.hasBeenActive) {
      // 文档从未被用户激活：浏览器必定拦截自动播放，先把 DSP 预加载好。
      await _ensureWorklet(context);
      _notice = _gestureNotice;
      throw _WebEffectsException(_gestureNotice);
    }
    // resume() 必须在用户手势所在的同一个任务里调用，否则会被浏览器拦截。
    final resume = context.resume().toDart.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    await _ensureWorklet(context);
    await _waitForRunning(context, resume);
    if (context.state != 'running') {
      _notice = _gestureNotice;
      throw _WebEffectsException(_gestureNotice);
    }
    await _openInput(context);
    _running = true;
    _failed = false;
    _notice = null;
    _workletError = null;
    _syncChain();
    return _status();
  }

  /// 停止监听：断开节点、停掉轨道、关闭上下文，但保留效果链内容。
  Future<Map<String, dynamic>> _stop() async {
    final capture = _mstp;
    _mstp = null;
    if (capture != null) {
      await capture.stop();
    }
    final node = _node;
    _node = null;
    if (node != null) {
      node.port.onmessage = null;
      try {
        node.disconnect();
      } catch (_) {
        // 节点可能已经被浏览器回收。
      }
    }
    final source = _source;
    _source = null;
    if (source != null) {
      try {
        source.disconnect();
      } catch (_) {
        // 同上。
      }
    }
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final track in stream.getTracks().toDart) {
        try {
          track.stop();
        } catch (_) {
          // 忽略停止轨道的异常。
        }
      }
    }
    final context = _context;
    _context = null;
    _workletReady = false;
    if (context != null) {
      try {
        await context.close().toDart;
      } catch (_) {
        // 上下文可能已经被浏览器关闭。
      }
    }
    _running = false;
    _inputPeak = 0;
    _outputPeak = 0;
    _captureSampleRate = null;
    _captureChannels = null;
    _captureLatencyMs = null;
    _capturePath = 'none';
    return _status();
  }

  Future<void> _ensureWorklet(web.AudioContext context) async {
    if (_workletReady) return;
    try {
      await context.audioWorklet.addModule(_workletModule).toDart;
    } catch (error) {
      throw _WebEffectsException(
        '无法加载效果器 DSP 模块「$_workletModule」：$error'
        '（请确认 web/effects_worklet.js 已随构建发布到 base href 之下）。',
      );
    }
    _workletReady = true;
  }

  /// 等待浏览器放行音频上下文。
  Future<void> _waitForRunning(
    web.AudioContext context,
    Future<void> resume,
  ) async {
    try {
      await resume.timeout(const Duration(seconds: 2));
    } catch (_) {
      // 被拦截时 resume() 会挂起或超时。
    }
    for (var attempt = 0; attempt < 20; attempt++) {
      if (context.state == 'running') return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 申请麦克风并搭好 `麦克风 → worklet → 扬声器` 的链路。
  ///
  /// 采集侧优先走 `MediaStreamTrackProcessor`（低延迟插入式流），它比
  /// `MediaStreamAudioSourceNode` 少一段浏览器内部缓冲；不支持或出问题时
  /// 自动回退到 source node。
  Future<void> _openInput(web.AudioContext context) async {
    if (_node != null) return;
    final stream = await _requestMicrophone(context);
    _readCaptureSettings(stream);
    final node = web.AudioWorkletNode(
      context,
      _processorName,
      web.AudioWorkletNodeOptions(
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: _stereoChannels,
        channelCount: 2,
        channelCountMode: 'explicit',
      ),
    );
    node.port.onmessage = _onWorkletMessage.toJS;
    node.connect(context.destination);
    _stream = stream;
    _node = node;
    final label = _trackLabel(stream);
    if (label != null) _inputDevice = label;

    if (await _tryMstpCapture(context, stream, node)) return;
    _connectSourceNode(context, stream, node);
  }

  /// 连接兼容路径：`MediaStreamAudioSourceNode` → worklet。
  void _connectSourceNode(
    web.AudioContext context,
    web.MediaStream stream,
    web.AudioWorkletNode node,
  ) {
    try {
      final source = context.createMediaStreamSource(stream);
      source.connect(node);
      _source = source;
      _capturePath = _capturePathSourceNode;
    } catch (error) {
      _workletError = '无法连接麦克风输入：$error';
    }
  }

  /// 尝试改用 `MediaStreamTrackProcessor` 采集帧。
  ///
  /// 成功时 worklet 从端口取采集帧（`_inputMode` = `port`），失败时调用方
  /// 回退到 source node 路径（`_inputMode` = `node`）。
  Future<bool> _tryMstpCapture(
    web.AudioContext context,
    web.MediaStream stream,
    web.AudioWorkletNode node,
  ) async {
    if (!MstpCapture.isSupported) return false;
    // 采集采样率必须与上下文一致：worklet 里的 DSP 按上下文速率跑，
    // 不一致时不能直接喂原始帧。
    final contextRate = context.sampleRate.round();
    if (_captureSampleRate != null && _captureSampleRate != contextRate) {
      return false;
    }
    final capture = await MstpCapture.start(
      stream: stream,
      onFrame: (buffer, frames, sampleRate) =>
          _postCapturedFrames(node, buffer, frames, sampleRate),
      onError: (error) => _fallbackToSourceNode(context, stream, node, error),
    );
    if (capture == null) return false;
    _mstp = capture;
    _postInputMode(node, 'port');
    try {
      await capture.firstFrame.timeout(const Duration(seconds: 2));
    } catch (_) {
      // 没有按时收到帧：回退到 source node 路径。
      await capture.stop();
      if (identical(_mstp, capture)) _mstp = null;
      if (_capturePath == _capturePathSourceNode) {
        // 读流出错时 [onError] 已经回退并连好了兼容路径，不要重复连接。
        return true;
      }
      // 切回音频节点输入模式，否则 worklet 会继续等端口里的样本而静音。
      _postInputMode(node, 'node');
      return false;
    }
    _capturePath = _capturePathMstp;
    return true;
  }

  /// 低延迟采集中途失败：切回 source node 路径，保证不会静音。
  void _fallbackToSourceNode(
    web.AudioContext context,
    web.MediaStream stream,
    web.AudioWorkletNode node,
    Object error,
  ) {
    if (_capturePath == _capturePathSourceNode) return;
    final capture = _mstp;
    _mstp = null;
    if (capture != null) {
      unawaited(capture.stop());
    }
    _postInputMode(node, 'node');
    _connectSourceNode(context, stream, node);
    _workletError ??= '低延迟采集不可用，已切回兼容路径：$error';
  }

  /// 把一帧采集样本送进 worklet 的端口输入队列。
  void _postCapturedFrames(
    web.AudioWorkletNode node,
    JSArrayBuffer buffer,
    int frames,
    int sampleRate,
  ) {
    if (frames <= 0) return;
    final message = JSObject();
    message.setProperty('type'.toJS, 'input'.toJS);
    message.setProperty('buffer'.toJS, buffer);
    message.setProperty('frames'.toJS, frames.toJS);
    message.setProperty('sampleRate'.toJS, sampleRate.toJS);
    node.port.postMessage(message);
  }

  /// 告诉 worklet 该从哪一路取输入：`port`（端口注入的采集帧）或 `node`。
  void _postInputMode(web.AudioWorkletNode node, String mode) {
    final message = JSObject();
    message.setProperty('type'.toJS, 'inputMode'.toJS);
    message.setProperty('mode'.toJS, mode.toJS);
    node.port.postMessage(message);
  }

  /// 申请单声道、关闭全部采集处理的麦克风。
  ///
  /// 约束取舍（依据 Chromium 与 Web Audio 的实现）：
  /// - 关闭三项处理后才可能走到 Chromium 的未处理采集路径，缓冲直通设备；
  /// - `latency` 只在上述路径生效，Linux 的 PulseAudio 后端不上报缓冲能力，
  ///   约束会被夹回默认缓冲（无收益但无害），因此先问浏览器是否支持；
  /// - `sampleRate` 取上下文采样率作理想值：与设备一致时省掉
  ///   `MediaStreamAudioSourceNode` 边界处的重采样，不一致时浏览器仍会自行转换。
  Future<web.MediaStream> _requestMicrophone(web.AudioContext context) async {
    final constraints = web.MediaTrackConstraints(
      echoCancellation: false.toJS,
      noiseSuppression: false.toJS,
      autoGainControl: false.toJS,
      channelCount: 1.0.toJS,
    );
    if (_supportsConstraint('latency')) {
      constraints.setProperty('latency'.toJS, 0.005.toJS);
    }
    final rate = context.sampleRate;
    if (rate.isFinite && rate > 0 && _supportsConstraint('sampleRate')) {
      constraints.setProperty('sampleRate'.toJS, rate.toDouble().toJS);
    }
    try {
      return await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: constraints))
          .toDart;
    } catch (error) {
      throw _WebEffectsException(_describeMediaError(error));
    }
  }

  /// 浏览器是否识别某个采集约束（不支持的约束会被静默忽略）。
  bool _supportsConstraint(String name) {
    try {
      final supported = web.window.navigator.mediaDevices
          .getSupportedConstraints()
          .dartify();
      if (supported is Map) return supported[name] == true;
    } catch (_) {
      // 没有 getSupportedConstraints 或返回值不可序列化时按不支持处理。
    }
    return false;
  }

  /// 记录采集轨道的实际设置；浏览器可能不提供，因此只用于诊断。
  void _readCaptureSettings(web.MediaStream stream) {
    try {
      for (final track in stream.getAudioTracks().toDart) {
        final settings = track.getSettings().dartify();
        if (settings is! Map) continue;
        final rate = settings['sampleRate'];
        final channels = settings['channelCount'];
        final latency = settings['latency'];
        if (rate is num && rate > 0) _captureSampleRate = rate.round();
        if (channels is num && channels > 0) {
          _captureChannels = channels.round();
        }
        if (latency is num && latency >= 0) _captureLatencyMs = latency * 1000;
        return;
      }
    } catch (_) {
      // 个别浏览器不提供轨道设置。
    }
  }

  String? _trackLabel(web.MediaStream stream) {
    try {
      for (final track in stream.getAudioTracks().toDart) {
        final label = track.label.trim();
        if (label.isNotEmpty) return label;
      }
    } catch (_) {
      // 浏览器可能隐藏设备名。
    }
    return null;
  }

  String _describeMediaError(Object error) {
    final name = _errorName(error);
    final text = '$error';
    if (name == 'NotAllowedError' ||
        name == 'PermissionDeniedError' ||
        text.contains('Permission denied')) {
      return _micDeniedNotice;
    }
    if (name == 'NotFoundError' ||
        name == 'DevicesNotFoundError' ||
        text.contains('Requested device not found')) {
      return '未找到可用的音频输入设备：请连接声卡或麦克风后重试。';
    }
    if (name == 'NotReadableError' ||
        name == 'TrackStartError' ||
        text.contains('Could not start audio source')) {
      return '麦克风被其它程序占用，请关闭占用后重试。';
    }
    if (name == 'OverconstrainedError' || name == 'ConstraintNotSatisfiedError') {
      return '当前麦克风不支持单声道输入，请更换设备后重试。';
    }
    if (name == 'SecurityError' ||
        text.contains('secure context') ||
        text.contains('HTTPS') ||
        text.contains('localhost')) {
      return _secureContextNotice;
    }
    return '无法打开麦克风：$error';
  }

  String _errorName(Object error) {
    try {
      final name = (error as JSObject).getProperty<JSString?>('name'.toJS);
      return name?.toDart ?? '';
    } catch (_) {
      // 不是 JS 对象时按文本匹配。
      return '';
    }
  }

  /// 追加一个内置效果器（上限 8 块）。
  Future<Map<String, dynamic>> _addBuiltin(Map<String, dynamic> args) async {
    final kind = args['kind']?.toString() ?? '';
    final spec = _effectCatalog[kind];
    if (spec == null) {
      throw _WebEffectsException('未知内置效果器。');
    }
    if (_chain.length >= _maxEffects) {
      throw _WebEffectsException('最多添加 8 个效果器。');
    }
    final slot = _EffectSlot(spec);
    _chain.add(slot);
    _post({
      'type': 'add',
      'index': _chain.length - 1,
      'kind': kind,
      'parameters': slot.values,
    });
    return _status();
  }

  /// 修改某个效果器的参数值。
  Future<Map<String, dynamic>> _setParameter(Map<String, dynamic> args) async {
    final index = _indexOf(args);
    final slot = _chain[index];
    final parameter = _intArg(args, 'parameter');
    if (parameter < 0 || parameter >= slot.values.length) {
      throw _WebEffectsException('无效效果器参数。');
    }
    final raw = _doubleArg(args, 'value');
    if (!raw.isFinite) {
      throw _WebEffectsException('无效效果器参数。');
    }
    // 与原生一致：数值夹到量程内。
    final value = raw.clamp(
      slot.spec.parameters[parameter].min,
      slot.spec.parameters[parameter].max,
    );
    slot.values[parameter] = value;
    _post({
      'type': 'parameter',
      'index': index,
      'parameter': parameter,
      'value': value,
    });
    return _status();
  }

  /// 移除某个效果器。
  Future<Map<String, dynamic>> _remove(Map<String, dynamic> args) async {
    final index = _indexOf(args);
    _chain.removeAt(index);
    _post({'type': 'remove', 'index': index});
    return _status();
  }

  /// 旁通某个效果器（旁通即直通）。
  Future<Map<String, dynamic>> _setBypass(Map<String, dynamic> args) async {
    final index = _indexOf(args);
    final value = args['value'] == true;
    _chain[index].bypass = value;
    _post({'type': 'bypass', 'index': index, 'value': value});
    return _status();
  }

  /// 调整效果器顺序（与原生一致：先摘出再插入目标位置）。
  Future<Map<String, dynamic>> _move(Map<String, dynamic> args) async {
    final index = _indexOf(args);
    final destination = _intArg(args, 'destination');
    if (destination < 0 || destination >= _chain.length) {
      throw _WebEffectsException('无效排序位置。');
    }
    final slot = _chain.removeAt(index);
    _chain.insert(destination, slot);
    _post({'type': 'move', 'index': index, 'destination': destination});
    return _status();
  }

  /// 主输出音量（由 worklet 内部实现，主线程不再叠 GainNode）。
  Future<Map<String, dynamic>> _setGain(Map<String, dynamic> args) async {
    final value = _doubleArg(args, 'value').clamp(0.0, 1.0);
    _gain = value;
    _post({'type': 'gain', 'value': value});
    return _status();
  }

  /// 网页端缓冲由浏览器决定，此命令不生效，仅回报提示。
  Future<Map<String, dynamic>> _audioBuffer(Map<String, dynamic> args) async {
    _notice =
        '网页端监听缓冲由浏览器与系统音频栈决定，页面无法调整；'
        '效果链固定按 128 帧处理，输出缓冲见「声卡设置与延迟诊断」。';
    return _status();
  }

  /// 把主线程的效果链同步到 worklet（重建后调用）。
  void _syncChain() {
    _post({'type': 'reset'});
    for (var index = 0; index < _chain.length; index++) {
      final slot = _chain[index];
      _post({
        'type': 'add',
        'index': index,
        'kind': slot.spec.kind,
        'parameters': slot.values,
      });
      if (slot.bypass) {
        _post({'type': 'bypass', 'index': index, 'value': true});
      }
    }
    _post({'type': 'gain', 'value': _gain});
  }

  void _post(Map<String, Object?> message) {
    final node = _node;
    if (node == null) return;
    node.port.postMessage(_toJsObject(message));
  }

  /// 显式构造发往 worklet 的消息对象（避免依赖 jsify 对 int 的未定义行为）。
  JSObject _toJsObject(Map<String, Object?> message) {
    final result = JSObject();
    for (final entry in message.entries) {
      result.setProperty(entry.key.toJS, _toJsValue(entry.value));
    }
    return result;
  }

  JSAny? _toJsValue(Object? value) {
    if (value == null) return null;
    if (value is String) return value.toJS;
    if (value is bool) return value.toJS;
    if (value is int) return value.toDouble().toJS;
    if (value is double) return value.toJS;
    if (value is List<double>) {
      return value.map((item) => item.toJS).toList().toJS;
    }
    return null;
  }

  /// 接收 worklet 的电平与错误回报。
  void _onWorkletMessage(web.MessageEvent event) {
    final payload = event.data?.dartify();
    if (payload is! Map<Object?, Object?>) return;
    final type = payload['type'];
    if (type == 'meter') {
      _inputPeak = _toDouble(payload['input']);
      _outputPeak = _toDouble(payload['output']);
      return;
    }
    if (type == 'error') {
      _workletError = '效果器运行错误：${payload['message'] ?? '未知错误'}';
    }
  }

  /// 完整状态（与原生 status() 字段结构保持一致）。
  Map<String, dynamic> _status() {
    final context = _context;
    final sampleRate = context == null ? 48000 : context.sampleRate.round();
    final latency = _latencyBreakdown(context);
    final plugins = <Map<String, dynamic>>[];
    final wetOnly = <String>[];
    for (final slot in _chain) {
      plugins.add(<String, dynamic>{
        'name': slot.spec.title,
        'bypass': slot.bypass,
        'kind': slot.spec.kind,
        'parameters': <Map<String, dynamic>>[
          for (var index = 0; index < slot.spec.parameters.length; index++)
            <String, dynamic>{
              'name': slot.spec.parameters[index].name,
              'min': slot.spec.parameters[index].min,
              'max': slot.spec.parameters[index].max,
              'value': slot.values[index],
              'unit': slot.spec.parameters[index].unit,
            },
        ],
      });
      if (!slot.bypass && _isWetOnly(slot)) {
        wetOnly.add(slot.spec.title);
      }
    }
    return <String, dynamic>{
      'audioOpen': _running,
      'backend': _backendName,
      'device': '浏览器音频设备',
      'inputDevice': _inputDevice,
      'outputDevice': '系统默认输出',
      'requestedBuffer': _renderQuantum,
      'setupNotice': _workletError ?? _notice,
      'pipewireQuantum': '',
      'inputChannels': _stream == null ? 0 : (_captureChannels ?? 1),
      'outputChannels': 2,
      'inputLatencyMs': 0.0,
      'outputLatencyMs': latency.deviceMs,
      'pluginLatencyMs': 0.0,
      // 只有输出侧（图内缓冲 + 设备输出）有浏览器读数；采集侧必须环回实测。
      'latencyScope': 'output-only',
      'latencyMs': latency.totalMs,
      'latencyAvailable': context != null,
      'baseLatencyMs': latency.baseMs,
      'captureSampleRate': _captureSampleRate,
      'captureChannels': _captureChannels,
      'captureLatencyMs': _captureLatencyMs ?? 0.0,
      'capturePath': _capturePath,
      'blockMs': _renderQuantum * 1000.0 / sampleRate,
      'xruns': -1,
      'cpu': 0.0,
      'cpuAvailable': false,
      'wetOnly': wetOnly,
      'running': _running,
      'failed': _failed || _contextFailed(context),
      'inputPeak': _inputPeak,
      'outputPeak': _outputPeak,
      'gain': _gain,
      'sampleRate': sampleRate,
      'bufferSize': _renderQuantum,
      'plugins': plugins,
    };
  }

  /// 混响 / 延迟的混音量拉满时视为全湿效果。
  bool _isWetOnly(_EffectSlot slot) {
    if (slot.spec.kind != 'reverb' && slot.spec.kind != 'delay') return false;
    if (slot.values.length < 3) return false;
    return slot.values[2] >= 0.999;
  }

  bool _contextFailed(web.AudioContext? context) {
    if (!_running || context == null) return false;
    final state = context.state;
    return state == 'closed' || state == 'interrupted';
  }

  /// 浏览器报告的延迟构成。
  ///
  /// `baseLatency` 是图内输出缓冲（Chromium 上约等于渲染回调块长），
  /// `outputLatency` 是音频栈到硬件输出的排队时间。两者只覆盖输出侧，
  /// 采集缓冲（Linux 上由 PulseAudio/PipeWire 决定）没有对应 API，
  /// 所以网页端的往返延迟只能靠环回实测，不能拿这里的和当成实测值。
  ({double baseMs, double deviceMs, double totalMs}) _latencyBreakdown(
    web.AudioContext? context,
  ) {
    if (context == null) {
      return (baseMs: 0, deviceMs: 0, totalMs: 0);
    }
    var baseMs = 0.0;
    var deviceMs = 0.0;
    try {
      final base = context.baseLatency;
      if (base.isFinite && base > 0) baseMs = base * 1000.0;
    } catch (_) {
      // 浏览器未提供 baseLatency。
    }
    try {
      final output = context.outputLatency;
      if (output.isFinite && output > 0) deviceMs = output * 1000.0;
    } catch (_) {
      // Firefox 等浏览器未提供 outputLatency。
    }
    return (baseMs: baseMs, deviceMs: deviceMs, totalMs: baseMs + deviceMs);
  }

  int _indexOf(Map<String, dynamic> args) {
    final index = _intArg(args, 'index');
    if (index < 0 || index >= _chain.length) {
      throw _WebEffectsException('效果器已不存在。');
    }
    return index;
  }

  int _intArg(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is int) return value;
    if (value is double && value.isFinite) return value.round();
    throw _WebEffectsException('无效效果器参数。');
  }

  double _doubleArg(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is num) return value.toDouble();
    throw _WebEffectsException('无效效果器参数。');
  }

  double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    return 0;
  }

  /// 用户激活状态：瞬时激活表示手势正在处理中，粘性激活表示页面曾被点击过。
  ({bool isActive, bool hasBeenActive}) _userActivation() {
    try {
      final activation = web.window.navigator.userActivation;
      return (
        isActive: activation.isActive,
        hasBeenActive: activation.hasBeenActive,
      );
    } catch (_) {
      // 浏览器不支持 User Activation API：交给 resume() 后的状态检查兜底。
      return (isActive: false, hasBeenActive: true);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stop();
  }
}

/// 带干净中文文案的异常（避免 StateError 的 "Bad state: " 前缀）。
class _WebEffectsException implements Exception {
  const _WebEffectsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 效果链中的一块效果器。
class _EffectSlot {
  _EffectSlot(this.spec)
    : values = <double>[
        for (final parameter in spec.parameters) parameter.initial,
      ];

  final _EffectSpec spec;
  final List<double> values;
  bool bypass = false;
}

/// 单个参数的元数据（与原生 describeParameters() 对齐）。
class _ParameterSpec {
  const _ParameterSpec(this.name, this.min, this.max, this.initial, this.unit);

  final String name;
  final double min;
  final double max;
  final double initial;
  final String unit;
}

/// 内置效果器的定义。
class _EffectSpec {
  const _EffectSpec(this.kind, this.title, this.parameters);

  final String kind;
  final String title;
  final List<_ParameterSpec> parameters;
}

/// 11 种内置效果器（与 native/effects_host/builtin_effect.h 保持一致）。
const Map<String, _EffectSpec> _effectCatalog = <String, _EffectSpec>{
  'fuzz': _EffectSpec('fuzz', 'Fuzz 法兹', <_ParameterSpec>[
    _ParameterSpec('驱动', 1, 30, 12, ''),
    _ParameterSpec('音色', 200, 8000, 2500, 'Hz'),
    _ParameterSpec('输出', 0, 1, 0.4, ''),
  ]),
  'overdrive': _EffectSpec('overdrive', '过载 Overdrive', <_ParameterSpec>[
    _ParameterSpec('驱动', 1, 20, 4, ''),
    _ParameterSpec('音色', 200, 8000, 4000, 'Hz'),
    _ParameterSpec('输出', 0, 1, 0.6, ''),
  ]),
  'amp_clean': _EffectSpec('amp_clean', '美式清音箱头', <_ParameterSpec>[
    _ParameterSpec('增益', 0, 10, 2, ''),
    _ParameterSpec('低频', -12, 12, 0, 'dB'),
    _ParameterSpec('中频', -12, 12, 0, 'dB'),
    _ParameterSpec('高频', -12, 12, 0, 'dB'),
    _ParameterSpec('主音量', 0, 1, 0.5, ''),
    _ParameterSpec('箱体', 0, 1, 1, ''),
  ]),
  'amp_chime': _EffectSpec('amp_chime', '英式清脆箱头', <_ParameterSpec>[
    _ParameterSpec('增益', 0, 10, 4, ''),
    _ParameterSpec('低频', -12, 12, 0, 'dB'),
    _ParameterSpec('中频', -12, 12, 0, 'dB'),
    _ParameterSpec('高频', -12, 12, 0, 'dB'),
    _ParameterSpec('主音量', 0, 1, 0.5, ''),
    _ParameterSpec('箱体', 0, 1, 1, ''),
  ]),
  'amp_crunch': _EffectSpec('amp_crunch', '英式摇滚箱头', <_ParameterSpec>[
    _ParameterSpec('增益', 0, 10, 5, ''),
    _ParameterSpec('低频', -12, 12, 0, 'dB'),
    _ParameterSpec('中频', -12, 12, 0, 'dB'),
    _ParameterSpec('高频', -12, 12, 0, 'dB'),
    _ParameterSpec('主音量', 0, 1, 0.5, ''),
    _ParameterSpec('箱体', 0, 1, 1, ''),
  ]),
  'amp_modern': _EffectSpec('amp_modern', '现代高增益箱头', <_ParameterSpec>[
    _ParameterSpec('增益', 0, 10, 6, ''),
    _ParameterSpec('低频', -12, 12, 0, 'dB'),
    _ParameterSpec('中频', -12, 12, 0, 'dB'),
    _ParameterSpec('高频', -12, 12, 0, 'dB'),
    _ParameterSpec('主音量', 0, 1, 0.5, ''),
    _ParameterSpec('箱体', 0, 1, 1, ''),
  ]),
  'wah': _EffectSpec('wah', '哇音 Wah', <_ParameterSpec>[
    _ParameterSpec('位置', 0, 1, 0.5, ''),
    _ParameterSpec('共振', 0.5, 8, 2, 'Q'),
    _ParameterSpec('干湿比', 0, 1, 1, ''),
    _ParameterSpec('输出', 0, 1, 0.7, ''),
    _ParameterSpec('自动', 0, 1, 0, ''),
    _ParameterSpec('速度', 0.1, 5, 1, 'Hz'),
    _ParameterSpec('深度', 0, 1, 0.8, ''),
  ]),
  'compressor': _EffectSpec('compressor', '压缩 Compressor', <_ParameterSpec>[
    _ParameterSpec('阈值', -60, 0, -24, 'dB'),
    _ParameterSpec('压缩比', 1, 12, 4, ':1'),
    _ParameterSpec('启动', 1, 100, 10, 'ms'),
    _ParameterSpec('释放', 20, 1000, 300, 'ms'),
    _ParameterSpec('补偿', 0, 18, 3, 'dB'),
  ]),
  'reverb': _EffectSpec('reverb', '混响 Reverb', <_ParameterSpec>[
    _ParameterSpec('空间', 0, 1, 0.5, ''),
    _ParameterSpec('阻尼', 0, 1, 0.5, ''),
    _ParameterSpec('干湿比', 0, 1, 0.25, ''),
  ]),
  'delay': _EffectSpec('delay', '延迟 Delay', <_ParameterSpec>[
    _ParameterSpec('时间', 20, 1500, 350, 'ms'),
    _ParameterSpec('反馈', 0, 0.9, 0.35, ''),
    _ParameterSpec('干湿比', 0, 1, 0.25, ''),
  ]),
  'pitch': _EffectSpec('pitch', '移调 Pitch', <_ParameterSpec>[
    _ParameterSpec('移调', -12, 12, 0, '半音'),
    _ParameterSpec('干湿比', 0, 1, 1, ''),
    _ParameterSpec('输出', 0, 1, 1, ''),
  ]),
};
