import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/band/band_controller.dart';
import 'package:guitarbook/features/band/chord_progression.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

/// 测试用的循环音频：记录所有调用，并暴露可设置的播放位置。
class _FakeAudio implements PositionedLoopAudio {
  final List<MetronomePattern> prepared = [];
  final List<Duration> playAtOffsets = [];
  final List<double> gains = [];
  int playCount = 0;
  int silenceCount = 0;
  int clearCount = 0;
  int disposeCount = 0;
  bool failOnPrepare = false;
  Duration _position = Duration.zero;

  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) async {
    if (failOnPrepare) throw StateError('准备失败');
    prepared.add(pattern);
  }

  @override
  void play() => playCount++;

  @override
  void playAt(Duration offset) {
    playCount++;
    playAtOffsets.add(offset);
    // 循环位置包含启动偏移。
    _position = offset;
  }

  @override
  void setGain(double gain) => gains.add(gain);

  @override
  Duration get position => _position;

  set position(Duration value) => _position = value;

  @override
  void silence() => silenceCount++;

  @override
  Future<void> clear() async => clearCount++;

  @override
  Future<void> dispose() async => disposeCount++;
}

/// 4/4 拍、100 bpm 下一小节的长度：2.4 秒。
const Duration _bar = Duration(milliseconds: 2400);

/// 挑一个至少有两个和弦的进行，方便检查和弦切换。
ChordProgression _multiChordProgression() => bandProgressions.firstWhere(
  (progression) => progression.chords.length >= 2,
  orElse: () => bandProgressions.first,
);

/// 挑一个小节数够多的进行，方便检查进行内的小节序号。
ChordProgression _multiBarProgression() => bandProgressions.firstWhere(
  (progression) => progression.bars >= 8,
  orElse: () => bandProgressions.first,
);

void main() {
  group('乐队和弦进行控制器', () {
    test('启动时按鼓机相位对齐', () async {
      final audio = _FakeAudio();
      final controller = BandController(
        audioFactory: () => audio,
        drumPosition: () => const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));

      await controller.enable();

      expect(audio.prepared.length, 1);
      expect(audio.playAtOffsets, [const Duration(milliseconds: 300)]);
      expect(controller.enabled, isTrue);
      expect(controller.playing, isTrue);
      expect(controller.error, isNull);
      expect(audio.gains.last, controller.volume);
    });

    test('没有鼓机时从第一小节开始', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);

      await controller.enable();

      expect(audio.playAtOffsets, [Duration.zero]);
    });

    test('当前和弦跟随播放位置', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      final progression = _multiChordProgression();
      controller.setProgression(progression);
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));

      await controller.enable();

      // 走到第二小节。
      audio.position = _bar;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final perChord = progression.barsPerChord <= 0
          ? 1
          : progression.barsPerChord;
      final expectedIndex = (1 % progression.bars) ~/ perChord;
      expect(controller.currentChordIndex, expectedIndex);
      expect(
        controller.currentChord?.name,
        progression.chordAt(expectedIndex).name,
      );
    });

    test('和弦没有变化时不通知界面', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      await controller.enable();
      // 第一次刷新会报出当前和弦，之后位置不变就不再通知。
      await Future<void>.delayed(const Duration(milliseconds: 150));

      var notifications = 0;
      controller.addListener(() => notifications++);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(notifications, 0);
    });

    test('切换进行与演奏方式会重新渲染', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      final progression = _multiChordProgression();
      controller.setProgression(progression);
      await controller.enable();
      expect(audio.prepared.length, 1);

      controller.setProgression(progression);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(audio.prepared.length, 2);

      controller.setStyle(ChordPlayStyle.arpeggio);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(audio.prepared.length, 3);
      expect(controller.style, ChordPlayStyle.arpeggio);
    });

    test('重新渲染保持当前相位，不跳回第一小节', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      await controller.enable();

      audio.position = const Duration(milliseconds: 600);
      controller.setStyle(ChordPlayStyle.strum);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(audio.playAtOffsets.last, const Duration(milliseconds: 600));
    });

    test('音量限制在 0~1 并写入增益', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      await controller.enable();

      controller.setVolume(1.5);
      expect(controller.volume, 1.0);
      expect(audio.gains.last, 1.0);

      controller.setVolume(-0.4);
      expect(controller.volume, 0.0);
      expect(audio.gains.last, 0.0);
    });

    test('停止时静音并释放音频', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      await controller.enable();

      await controller.disable();

      expect(audio.silenceCount, greaterThanOrEqualTo(1));
      expect(audio.clearCount, greaterThanOrEqualTo(1));
      expect(audio.disposeCount, 1);
      expect(controller.playing, isFalse);
      expect(controller.enabled, isFalse);
      expect(controller.currentChord, isNull);
    });

    test('速度与拍号没有变化时不重新渲染', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));
      await controller.enable();
      expect(audio.prepared.length, 1);
      final plays = audio.playCount;

      // 鼓机每敲一次鼓都会同步一次，但参数没变就不该重画整段进行。
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(audio.prepared.length, 1);
      expect(audio.playCount, plays);

      // 速度变了才按新的网格重画。
      controller.setGroove(bpm: 120, meter: const DrumMeter(4, 4));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(audio.prepared.length, 2);
      expect(audio.playCount, plays + 1);
    });

    test('切换演奏方式不会跳回第一小节', () async {
      final audio = _FakeAudio();
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);
      final progression = _multiBarProgression();
      controller.setProgression(progression);
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));
      await controller.enable();

      // 播到第三小节中间。
      final position = _bar * 3 + const Duration(milliseconds: 300);
      audio.position = position;
      controller.setStyle(ChordPlayStyle.arpeggio);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final loop = _bar * progression.bars;
      final offset = audio.playAtOffsets.last;
      // 偏移量落在整条循环里，且不超过循环总长（否则会 seek 越界）。
      expect(offset.inMicroseconds, lessThan(loop.inMicroseconds));
      expect(
        offset.inMicroseconds,
        position.inMicroseconds % loop.inMicroseconds,
      );
      // 小节内的相位不变，进行里的小节序号也被保住。
      expect(
        offset.inMicroseconds % _bar.inMicroseconds,
        const Duration(milliseconds: 300).inMicroseconds,
      );
    });

    test('相位漂移后的对齐不会重置进行', () async {
      final audio = _FakeAudio();
      final controller = BandController(
        audioFactory: () => audio,
        drumPosition: () => const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);
      final progression = _multiBarProgression();
      controller.setProgression(progression);
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));
      await controller.enable();

      // 和弦跑到鼓机前面一截，而且停在第五小节。
      audio.position = _bar * 4 + const Duration(milliseconds: 1000);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final loop = _bar * progression.bars;
      final offset = audio.playAtOffsets.last;
      expect(offset.inMicroseconds, lessThan(loop.inMicroseconds));
      expect(offset.inMicroseconds ~/ _bar.inMicroseconds, 4 % progression.bars);
      expect(
        offset.inMicroseconds % _bar.inMicroseconds,
        const Duration(milliseconds: 300).inMicroseconds,
      );
    });

    test('准备失败时给出错误而不是抛出', () async {
      final audio = _FakeAudio()..failOnPrepare = true;
      final controller = BandController(audioFactory: () => audio);
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.error, isNotNull);
      expect(controller.error, contains('和弦进行'));
      expect(controller.playing, isFalse);
    });

    test('相位漂移后重新对齐到鼓机', () async {
      final audio = _FakeAudio();
      final controller = BandController(
        audioFactory: () => audio,
        drumPosition: () => const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);
      controller.setGroove(bpm: 100, meter: const DrumMeter(4, 4));
      await controller.enable();

      // 和弦跑到鼓机前面一截。
      audio.position = const Duration(milliseconds: 1000);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(audio.playAtOffsets.length, greaterThanOrEqualTo(2));
      expect(audio.playAtOffsets.last, const Duration(milliseconds: 300));
    });
  });
}
