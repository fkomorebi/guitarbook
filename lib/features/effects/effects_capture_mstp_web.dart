import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// WebCodecs 的 `AudioData`（`package:web` 暂未收录，这里按用到的成员声明）。
@JS('AudioData')
extension type _AudioData._(JSObject _) implements JSObject {
  external int get numberOfFrames;
  external int get numberOfChannels;
  external String get format;
  external double get sampleRate;
  external double get timestamp;
  external void copyTo(JSFloat32Array destination, JSObject options);
  external void close();
}

/// 用 `MediaStreamTrackProcessor` 直接读取采集帧的低延迟采集通道。
///
/// 与 `MediaStreamAudioSourceNode` 的差别：后者在浏览器内部还要经过
/// `AudioConverter`（重采样）+ `PrimeWithSilence` + 6 批 FIFO，实测在本机
/// Scarlett 硬件环回上比直接读帧多约 13 ms；这里绕过那一段，把帧直接
/// 交给 worklet 处理。
///
/// 仅 Chromium 系浏览器提供音频插入式流；不支持、采样率不匹配或读帧失败时，
/// 调用方需要回退到 `MediaStreamAudioSourceNode`。
class MstpCapture {
  MstpCapture._(this._reader, this._onFrame, this._onError);

  final web.ReadableStreamDefaultReader _reader;
  final void Function(JSArrayBuffer buffer, int frames, int sampleRate) _onFrame;
  final void Function(Object error)? _onError;

  final Completer<void> _firstFrame = Completer<void>();

  bool _active = true;

  /// 第一帧到达（或失败）时完成；调用方用它判断该链路是否真的可用。
  Future<void> get firstFrame => _firstFrame.future;

  /// 浏览器是否提供音频 `MediaStreamTrackProcessor`。
  static bool get isSupported {
    try {
      return globalContext.has('MediaStreamTrackProcessor');
    } catch (_) {
      return false;
    }
  }

  /// 启动读取；返回 `null` 表示浏览器不支持或构造失败（调用方应回退）。
  ///
  /// [onFrame] 每收到一帧被调用一次，参数是单声道 `Float32` 的
  /// `ArrayBuffer`、采样数与采样率。
  /// [onError] 在读流中途失败时调用，调用方据此回退到 source node 路径。
  static Future<MstpCapture?> start({
    required web.MediaStream stream,
    required void Function(JSArrayBuffer buffer, int frames, int sampleRate)
    onFrame,
    void Function(Object error)? onError,
  }) async {
    final tracks = stream.getAudioTracks().toDart;
    if (tracks.isEmpty) return null;
    final web.MediaStreamTrackProcessor processor;
    try {
      processor = web.MediaStreamTrackProcessor(
        web.MediaStreamTrackProcessorInit(track: tracks.first),
      );
    } catch (_) {
      // 浏览器没有音频插入式流，或拒绝这条轨道。
      return null;
    }
    final web.ReadableStreamDefaultReader reader;
    try {
      reader =
          processor.readable.getReader() as web.ReadableStreamDefaultReader;
    } catch (_) {
      return null;
    }
    final capture = MstpCapture._(reader, onFrame, onError);
    unawaited(capture._run());
    return capture;
  }

  /// 停止读取并释放轨道。
  Future<void> stop() async {
    _active = false;
    try {
      await _reader.cancel().toDart;
    } catch (_) {
      // 读流可能已经结束。
    }
  }

  Future<void> _run() async {
    try {
      while (_active) {
        final web.ReadableStreamReadResult result;
        try {
          result = await _reader.read().toDart;
        } catch (error) {
          if (!_firstFrame.isCompleted) _firstFrame.completeError(error);
          _onError?.call(error);
          return;
        }
        if (result.done) break;
        final value = result.value;
        if (value == null) continue;
        final audio = value as _AudioData;
        try {
          final frames = audio.numberOfFrames;
          if (frames <= 0) continue;
          final channels = audio.numberOfChannels;
          final arrayBuffer = JSArrayBuffer(frames * 4);
          final view = JSFloat32Array(arrayBuffer);
          audio.copyTo(view, _planeOptions(0));
          if (channels > 1) {
            // 浏览器可能忽略 channelCount:1 而给出多声道，这里下混成单声道。
            final mono = view.toDart;
            final planeBuffer = JSArrayBuffer(frames * 4);
            final plane = JSFloat32Array(planeBuffer);
            for (var channel = 1; channel < channels; ++channel) {
              audio.copyTo(plane, _planeOptions(channel));
              final other = plane.toDart;
              for (var index = 0; index < frames; ++index) {
                mono[index] = (mono[index] + other[index]) / channels;
              }
            }
          }
          _onFrame(arrayBuffer, frames, audio.sampleRate.round());
          if (!_firstFrame.isCompleted) _firstFrame.complete();
        } finally {
          try {
            audio.close();
          } catch (_) {
            // 忽略释放异常。
          }
        }
      }
      if (!_firstFrame.isCompleted) {
        _firstFrame.completeError(StateError('采集流已结束'));
      }
    } catch (error) {
      if (!_firstFrame.isCompleted) _firstFrame.completeError(error);
      _onError?.call(error);
    }
  }

  /// `AudioData.copyTo` 的选项：只取指定平面。
  static JSObject _planeOptions(int planeIndex) {
    final options = JSObject();
    options.setProperty('planeIndex'.toJS, planeIndex.toJS);
    return options;
  }
}
