import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'metronome_audio.dart';
import 'metronome_pattern.dart';

MetronomeAudio createMetronomeAudio() => _WebMetronomeAudio();

class _WebMetronomeAudio implements MetronomeAudio {
  web.AudioContext? _context;
  web.AudioBuffer? _buffer;
  web.AudioBufferSourceNode? _source;
  double _startedAt = 0;

  @override
  Future<void> unlock() {
    final context = _context ??= web.AudioContext(
      web.AudioContextOptions(latencyHint: 'interactive'.toJS),
    );
    // Invoke resume during the click event, rather than after async loading.
    return context.resume().toDart.then((_) {
      if (context.state != 'running') {
        throw StateError('Browser did not unlock audio');
      }
    });
  }

  @override
  Future<void> prepare(MetronomePattern pattern) async {
    final buffer = _context!.createBuffer(
      1,
      pattern.samples.length,
      pattern.sampleRate,
    );
    buffer.copyToChannel(pattern.samples.toJS, 0);
    _buffer = buffer;
  }

  @override
  void play() {
    final context = _context!;
    if (context.state != 'running') {
      throw StateError('Browser audio is suspended');
    }
    final source = context.createBufferSource()
      ..buffer = _buffer
      ..loop = true;
    source.connect(context.destination);
    _startedAt = context.currentTime;
    source.start(_startedAt);
    _source = source;
  }

  @override
  Duration get position {
    final context = _context!;
    if (_source == null || context.state != 'running') {
      throw StateError('Browser audio stopped unexpectedly');
    }
    return Duration(
      microseconds: ((context.currentTime - _startedAt) * 1000000).round(),
    );
  }

  @override
  void silence() {
    final source = _source;
    _source = null;
    if (source != null) {
      source.stop();
      source.disconnect();
    }
  }

  @override
  Future<void> clear() async {
    silence();
    _buffer = null;
  }

  @override
  Future<void> dispose() async {
    await clear();
    final context = _context;
    _context = null;
    if (context != null) await context.close().toDart;
  }
}
