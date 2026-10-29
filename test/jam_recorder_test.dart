import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/jam_recording/jam_recorder.dart';
import 'package:guitarbook/features/jam_recording/recording_audio.dart';
import 'package:guitarbook/features/jam_recording/shared_loop_input.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';
import 'package:guitarbook/features/looper/looper_controller.dart';
import 'looper_test.dart' show FakeInput, FakeOutput;

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a real Looper layer enters the mix and can stop independently',
    () async {
      final input = FakeInput();
      final shared = SharedLoopInput(input);
      final outputs = <RecordingAudio>{};
      final looper = LooperController(shared.lease(), () {
        final audio = RecordingAudio(FakeOutput(), outputs.remove);
        outputs.add(audio);
        return audio;
      });
      looper.mainPedal();
      await looper.settled;
      input.emit(14400);
      await flush();
      looper.mainPedal();
      await looper.settled;
      expect(looper.layers, 1);
      final r = JamRecorder(shared.lease(), outputs);
      await r.start();
      input.emit(16);
      await flush();
      expect(r.buffer!.sampleAt(8), greaterThan(12000));
      looper.stop();
      await looper.settled;
      expect(input.active, isTrue);
      input.emit(16);
      await flush();
      expect(r.buffer!.sampleAt(24), closeTo(12000, 1));
      r.dispose();
      looper.dispose();
      await r.settled;
      await looper.settled;
      await shared.dispose();
    },
  );

  test('source playback phase is resampled across the loop boundary', () async {
    final output = FakeOutput()..offset = const Duration(milliseconds: 1);
    final tap = RecordingAudio(output, (_) {});
    await tap.prepare(
      MetronomePattern.rendered(
        bpm: 100,
        beats: 4,
        sampleRate: 24000,
        framesPerBeat: 1,
        samples: Float32List.fromList([0, .1, .2, .3]),
      ),
    );
    tap.playAt(const Duration(milliseconds: 1));
    final block = tap.block(4);
    for (var i = 0; i < 4; i++) {
      expect(block(i), closeTo([.2, .25, .3, .15][i], .000001));
    }
    tap.silence();
    expect(tap.block(4)(0), 0);
    await tap.dispose();
  });

  test('input PCM samples survive odd byte boundaries', () async {
    final input = FakeInput();
    final r = JamRecorder(input, {});
    await r.start();
    input.stream!.add(Uint8List.fromList([0x00]));
    input.stream!.add(Uint8List.fromList([0x40, 0x00]));
    input.stream!.add(Uint8List.fromList([0xc0]));
    await flush();
    expect(r.buffer!.length, 2);
    expect(r.buffer!.sampleAt(0), 16384);
    expect(r.buffer!.sampleAt(1), -16384);
    r.dispose();
    await r.settled;
  });

  test(
    'three sources mix with gains, silent and removed loops disappear',
    () async {
      final input = FakeInput();
      final outputs = <RecordingAudio>{};
      Future<RecordingAudio> source(double value) async {
        final audio = RecordingAudio(FakeOutput(), outputs.remove);
        outputs.add(audio);
        await audio.prepare(
          MetronomePattern.rendered(
            bpm: 100,
            beats: 4,
            sampleRate: 48000,
            framesPerBeat: 4,
            samples: Float32List.fromList(List.filled(16, value)),
          ),
        );
        audio.play();
        return audio;
      }

      final drum = await source(.2);
      final loop = await source(.3);
      final r = JamRecorder(input, outputs)..memoryMiB = 8;
      await r.start();
      input.emit(4);
      await flush();
      expect(r.buffer!.sampleAt(0), closeTo((12000 / 32768 + .5) * 32767, 1));
      drum.setGain(.5);
      loop.silence();
      input.emit(4);
      await flush();
      expect(r.buffer!.sampleAt(4), closeTo((12000 / 32768 + .1) * 32767, 1));
      await drum.dispose();
      input.emit(4);
      await flush();
      expect(r.buffer!.sampleAt(8), closeTo(12000, 1));
      r.stop();
      await r.settled;
      expect(r.buffer!.length, 12);
      expect(input.active, isFalse);
      r.dispose();
      await r.settled;
      await loop.dispose();
    },
  );

  test(
    'recording and looper leases independently keep the input running',
    () async {
      final input = FakeInput();
      final shared = SharedLoopInput(input);
      final looper = shared.lease();
      final r = JamRecorder(shared.lease(), {});
      final received = <Uint8List>[];
      final stream = await looper.start(null);
      final sub = stream.listen(received.add);
      await r.start();
      input.emit(8);
      await flush();
      expect(received, hasLength(1));
      expect(r.buffer!.length, 8);
      r.stop();
      await r.settled;
      expect(input.active, isTrue);
      input.emit(8);
      await flush();
      expect(received, hasLength(2));
      await r.start();
      await looper.stop();
      expect(input.active, isTrue);
      input.emit(8);
      await flush();
      expect(r.buffer!.length, 8);
      r.dispose();
      await r.settled;
      expect(input.active, isFalse);
      await sub.cancel();
      await shared.dispose();
    },
  );

  test(
    'permission failure retries and cancellation during permission is safe',
    () async {
      final input = FakeInput()..denied = true;
      final shared = SharedLoopInput(input);
      final r = JamRecorder(shared.lease(), {});
      await r.start();
      expect(r.error, contains('permission denied'));
      input.denied = false;
      input.starting = Completer<void>();
      final pending = r.start();
      await flush();
      r.stop();
      input.starting!.complete();
      await pending;
      await r.settled;
      expect(r.recording, isFalse);
      expect(input.active, isFalse);
      input.starting = null;
      await r.start();
      input.stream!.addError(StateError('device lost'));
      await flush();
      await r.settled;
      expect(r.error, contains('device lost'));
      expect(r.recording, isFalse);
      r.dispose();
      await r.settled;
      await shared.dispose();
    },
  );
}
