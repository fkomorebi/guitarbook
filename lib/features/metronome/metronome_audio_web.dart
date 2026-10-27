import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'metronome_audio.dart';
import 'metronome_pattern.dart';

MetronomeAudio createMetronomeAudio() => _WebMetronomeAudio();

class _WebMetronomeAudio implements PositionedLoopAudio {
  _WebMetronomeAudio() {
    _clients++;
  }
  static int _clients = 0;
  static web.AudioContext? _sharedContext;
  bool _disposed = false;
  web.AudioContext? _context;
  web.AudioBuffer? _buffer;
  web.AudioBufferSourceNode? _source;
  double _startedAt = 0;
  double _gain = 1;
  web.GainNode? _gainNode;

  @override
  void setGain(double gain) {
    _gain = gain;
    _gainNode?.gain.value = gain;
  }

  @override
  Future<void> unlock() {
    final context = _context ??= _sharedContext ??= web.AudioContext(
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
  void play() => playAt(Duration.zero);

  @override
  void playAt(Duration offset) {
    silence();
    final context = _context!;
    if (context.state != 'running') {
      throw StateError('Browser audio is suspended');
    }
    final source = context.createBufferSource()
      ..buffer = _buffer
      ..loop = true;
    final gainNode = context.createGain();
    gainNode.gain.value = _gain;
    source.connect(gainNode);
    gainNode.connect(context.destination);
    _gainNode = gainNode;
    final seconds = offset.inMicroseconds / 1000000;
    _startedAt = context.currentTime - seconds;
    source.start(context.currentTime, seconds);
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
      _gainNode?.disconnect();
      _gainNode = null;
    }
  }

  @override
  Future<void> clear() async {
    silence();
    _buffer = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await clear();
    _context = null;
    _clients--;
    if (_clients == 0) {
      final context = _sharedContext;
      _sharedContext = null;
      if (context != null) await context.close().toDart;
    }
  }
}
