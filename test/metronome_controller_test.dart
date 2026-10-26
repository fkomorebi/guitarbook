import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/metronome/metronome_audio.dart';
import 'package:guitarbook/features/metronome/metronome_controller.dart';
import 'package:guitarbook/features/metronome/metronome_pattern.dart';

class FakeMetronomeAudio implements MetronomeAudio {
  Completer<void>? loading;
  int starts = 0;
  int unlocks = 0;
  int clears = 0;
  bool audible = false;
  bool released = false;
  bool failUnlock = false;
  bool failPrepare = false;
  Duration elapsed = Duration.zero;
  final prepared = <MetronomePattern>[];

  @override
  Future<void> unlock() async {
    unlocks++;
    if (failUnlock) throw StateError('Permission denied');
  }

  @override
  Future<void> prepare(MetronomePattern pattern) async {
    prepared.add(pattern);
    if (failPrepare) throw StateError('No audio device');
    await loading?.future;
  }

  @override
  void play() {
    starts++;
    audible = true;
  }

  @override
  Duration get position => elapsed;
  @override
  void silence() {
    audible = false;
  }

  @override
  Future<void> clear() async {
    clears++;
    audible = false;
  }

  @override
  Future<void> dispose() async {
    released = true;
    audible = false;
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'sound switches silence immediately and restart on the first beat',
    () async {
      final audio = FakeMetronomeAudio();
      final c = MetronomeController(audio)..start();
      await c.settled;
      expect(audio.audible, isTrue);
      c.configure(sound: false);
      expect(audio.audible, isFalse);
      expect(c.beat, 1);
      await c.settled;
      expect(audio.starts, 1);
      c.configure(sound: true);
      await c.settled;
      expect(audio.starts, 2);
      c.configure(accent: false);
      expect(audio.audible, isFalse);
      await c.settled;
      expect(audio.starts, 3);
      expect(audio.prepared.last.accent, isFalse);
      c.dispose();
      await c.settled;
    },
  );

  test(
    'audio runs once, display follows engine clock even after UI delay',
    () async {
      final audio = FakeMetronomeAudio();
      final c = MetronomeController(audio);
      c.start();
      expect(audio.unlocks, 1);
      expect(c.preparing, isTrue);
      await c.settled;
      expect(c.beat, 1);
      audio.elapsed = const Duration(milliseconds: 1870);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.beat, 4);
      expect(audio.starts, 1);
      c.stop();
      expect(audio.audible, isFalse);
      c.dispose();
      await c.settled;
      expect(audio.released, isTrue);
    },
  );

  test('stop during loading never starts a stale voice', () async {
    final audio = FakeMetronomeAudio()..loading = Completer<void>();
    final c = MetronomeController(audio)..start();
    await flush();
    c.stop();
    audio.loading!.complete();
    await c.settled;
    expect(audio.starts, 0);
    expect(c.running, isFalse);
    c.dispose();
    await c.settled;
  });

  test('rapid reconfiguration only plays final parameters', () async {
    final audio = FakeMetronomeAudio()..loading = Completer<void>();
    final c = MetronomeController(audio)..start();
    await flush();
    c.configure(bpm: 137);
    c.configure(beats: 7, accent: false);
    audio.loading!.complete();
    await c.settled;
    expect(audio.starts, 1);
    expect(audio.prepared.last.bpm, 137);
    expect(audio.prepared.last.beats, 7);
    expect(audio.prepared.last.accent, isFalse);
    c.dispose();
    await c.settled;
  });

  test(
    'dispose while loading cancels playback and releases resources',
    () async {
      final audio = FakeMetronomeAudio()..loading = Completer<void>();
      final c = MetronomeController(audio)..start();
      await flush();
      c.dispose();
      audio.loading!.complete();
      await c.settled;
      expect(audio.starts, 0);
      expect(audio.released, isTrue);
    },
  );

  test(
    'audio failure can recover into silent mode without reopening a device',
    () async {
      for (final unlockFailure in [false, true]) {
        final audio = FakeMetronomeAudio()
          ..failUnlock = unlockFailure
          ..failPrepare = !unlockFailure;
        final c = MetronomeController(audio)..start();
        await c.settled;
        expect(c.running, isFalse);
        expect(c.error, isNotNull);
        c.configure(sound: false);
        c.start();
        await c.settled;
        expect(c.running, isTrue);
        expect(c.beat, 1);
        expect(c.error, isNull);
        expect(audio.starts, 0);
        expect(audio.unlocks, 1);
        c.dispose();
        await c.settled;
      }
    },
  );
}
