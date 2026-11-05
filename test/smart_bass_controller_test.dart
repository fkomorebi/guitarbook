import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';
import 'package:guitarbook/features/looper/loop_audio.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';
import 'package:guitarbook/features/smart_bass/bass_pattern.dart';
import 'package:guitarbook/features/smart_bass/smart_bass_controller.dart';

/// 假输入：模拟工作台共享的音频通道。
class _FakeInput implements LoopInput {
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  bool started = false;
  bool stopped = false;

  void feed(Uint8List bytes) => _controller.add(bytes);

  @override
  Future<List<InputDevice>> devices() async => const <InputDevice>[];

  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async {
    started = true;
    return _controller.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

/// 假播放器：记录准备好的循环与播放相位。
class _FakeBassAudio implements PositionedLoopAudio {
  MetronomePattern? prepared;
  Duration? playedAt;
  double gain = 1;
  bool cleared = false;
  bool disposed = false;

  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) async {
    prepared = pattern;
  }

  @override
  void play() {
    playedAt ??= Duration.zero;
  }

  @override
  void playAt(Duration offset) {
    playedAt = offset;
  }

  @override
  void setGain(double value) {
    gain = value;
  }

  @override
  Duration get position => playedAt ?? Duration.zero;

  @override
  void silence() {}

  @override
  Future<void> clear() async {
    cleared = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 合成一个和弦的 PCM16 数据。
Uint8List _chordBytes(
  List<double> frequencies, {
  int sampleRate = 48000,
  int length = 8192,
}) {
  final samples = Float32List(length);
  for (var i = 0; i < length; i++) {
    final t = i / sampleRate;
    var value = 0.0;
    for (final frequency in frequencies) {
      value += math.sin(2 * math.pi * frequency * t);
      value += 0.5 * math.sin(4 * math.pi * frequency * t);
      value += 0.3 * math.sin(6 * math.pi * frequency * t);
    }
    samples[i] = value / (frequencies.length * 1.8);
  }
  final bytes = Uint8List(length * 2);
  for (var i = 0; i < length; i++) {
    final value = (samples[i] * 32767).round().clamp(-32768, 32767);
    bytes[2 * i] = value & 0xff;
    bytes[2 * i + 1] = (value >> 8) & 0xff;
  }
  return bytes;
}

List<List<bool>> _makeHits() {
  final rows = <List<bool>>[];
  for (var track = 0; track < drumTrackNames.length; track++) {
    rows.add(List<bool>.filled(16, false));
  }
  rows[0][0] = true;
  rows[0][8] = true;
  return rows;
}

void main() {
  const meter = DrumMeter(4, 4);
  final hits = _makeHits();

  test('开启后监听输入并识别和弦，低音循环与鼓机等长', () async {
    final input = _FakeInput();
    final audio = _FakeBassAudio();
    final controller = SmartBassController(
      input: input,
      audioFactory: () => audio,
    );
    addTearDown(controller.dispose);

    controller.setGroove(bpm: 120, meter: meter, hits: hits);
    await controller.enable();
    expect(input.started, isTrue);
    expect(controller.listening, isTrue);

    final chord = _chordBytes([261.63, 329.63, 392.0]);
    input.feed(chord.sublist(0, 8192));
    await Future<void>.delayed(Duration.zero);
    input.feed(chord.sublist(8192));
    await Future<void>.delayed(Duration.zero);

    expect(controller.chord, isNotNull);
    expect(controller.chord!.root, 0);
    expect(controller.chord!.quality, 'maj');

    // 交换发生在下一拍，等淡出与播放切换完成。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(controller.playing, isTrue);
    expect(audio.prepared, isNotNull);

    final drumPattern = renderDrums(
      120,
      hits,
      List<bool>.filled(5, false),
      0,
      meter: meter,
    );
    expect(audio.prepared!.samples.length, drumPattern.samples.length);
    expect(audio.prepared!.sampleRate, drumPattern.sampleRate);
  });

  test('低音相位跟随鼓机，并量化到下一拍', () async {
    final input = _FakeInput();
    final audio = _FakeBassAudio();
    var drumPosition = const Duration(milliseconds: 500);
    final controller = SmartBassController(
      input: input,
      audioFactory: () => audio,
      drumPosition: () => drumPosition,
    );
    addTearDown(controller.dispose);

    controller.setGroove(bpm: 120, meter: meter, hits: hits);
    await controller.enable();

    final chord = _chordBytes([261.63, 329.63, 392.0]);
    input.feed(chord.sublist(0, 8192));
    await Future<void>.delayed(Duration.zero);
    input.feed(chord.sublist(8192));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // 120 BPM 下一拍 500 ms，小节 2000 ms：鼓机在第二拍，低音从同一拍切入。
    expect(audio.playedAt, const Duration(milliseconds: 500));

    // 鼓机重新起拍后相位变了，低音要在 400 ms 内拉回同一拍。
    drumPosition = const Duration(milliseconds: 1200);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(audio.playedAt, const Duration(milliseconds: 1500));
  });

  test('可以切换低音风格与音量，停止后释放输入', () async {
    final input = _FakeInput();
    final audio = _FakeBassAudio();
    final controller = SmartBassController(
      input: input,
      audioFactory: () => audio,
    );
    addTearDown(controller.dispose);

    expect(controller.style, BassStyle.followKick);
    controller.setStyle(BassStyle.walking);
    expect(controller.style, BassStyle.walking);

    controller.setVolume(0.5);
    expect(controller.volume, 0.5);
    controller.setVolume(2);
    expect(controller.volume, 1);

    await controller.enable();
    await controller.disable();
    expect(controller.enabled, isFalse);
    expect(controller.listening, isFalse);
    expect(input.stopped, isTrue);
    expect(audio.disposed, isTrue);
  });

  test('输入静音时不识别和弦', () async {
    final input = _FakeInput();
    final controller = SmartBassController(
      input: input,
      audioFactory: () => _FakeBassAudio(),
    );
    addTearDown(controller.dispose);

    await controller.enable();
    final silence = Uint8List(4096 * 2);
    input.feed(silence);
    await Future<void>.delayed(Duration.zero);
    input.feed(silence);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(controller.chord, isNull);
    expect(controller.playing, isFalse);
  });
}
