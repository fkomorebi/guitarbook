import 'dart:typed_data';

import 'package:record/record.dart';

import '../metronome/metronome_audio.dart';
import '../metronome/metronome_audio_factory.dart';

abstract interface class LoopInput {
  Future<List<InputDevice>> devices();
  Future<Stream<Uint8List>> start(InputDevice? device);
  Future<void> stop();
  Future<void> dispose();
}

class RecorderLoopInput implements LoopInput {
  final _recorder = AudioRecorder();

  @override
  Future<List<InputDevice>> devices() => _recorder.listInputDevices();

  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async {
    if (!await _recorder.hasPermission()) {
      throw StateError('需要麦克风权限，请在系统或浏览器设置中允许后重试。');
    }
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
        device: device,
        streamBufferSize: 2048,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

PositionedLoopAudio createLoopAudio() =>
    createMetronomeAudio() as PositionedLoopAudio;
