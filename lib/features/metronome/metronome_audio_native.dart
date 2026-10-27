import 'dart:async';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'metronome_audio.dart';
import 'metronome_pattern.dart';

MetronomeAudio createMetronomeAudio() => _NativeMetronomeAudio();

class _NativeMetronomeAudio implements PositionedLoopAudio {
  _NativeMetronomeAudio() {
    _clients++;
    _id = _nextId++;
  }

  // Navigation can create a new page before the previous load has finished.
  // Share the engine lifetime and serialize loading/teardown across pages.
  static int _clients = 0;
  static int _nextId = 0;
  late final int _id;
  int _loadId = 0;
  static bool _ownsEngine = false;
  static Future<void> _lifecycle = Future<void>.value();
  Future<void> _serialize(Future<void> Function() action) {
    final result = _lifecycle.then((_) => action());
    _lifecycle = result.catchError((Object _) {});
    return result;
  }

  SoLoud get _engine => SoLoud.instance;
  AudioSource? _source;
  SoundHandle? _voice;
  bool _disposed = false;
  double _gain = 1;

  @override
  void setGain(double gain) {
    _gain = gain;
    final voice = _voice;
    if (voice != null &&
        _engine.isInitialized &&
        _engine.getIsValidVoiceHandle(voice)) {
      _engine.setVolume(voice, gain);
    }
  }

  @override
  Future<void> unlock() async {}

  @override
  Future<void> prepare(MetronomePattern pattern) => _serialize(() async {
    if (!_engine.isInitialized) {
      await _engine.init(sampleRate: 48000, bufferSize: 512);
      _ownsEngine = true;
    }
    _source = await _engine.loadMem('loop-$_id-${_loadId++}', pattern.toWav());
  });

  @override
  void play() {
    playAt(Duration.zero);
  }

  @override
  void playAt(Duration offset) {
    final oldVoice = _voice;
    if (oldVoice != null && _engine.getIsValidVoiceHandle(oldVoice)) {
      unawaited(_engine.stop(oldVoice));
    }
    _voice = _engine.play(_source!, looping: true, paused: true, volume: _gain);
    if (!_engine.getIsValidVoiceHandle(_voice!)) {
      throw StateError('Could not start metronome audio');
    }
    if (offset > Duration.zero) _engine.seek(_voice!, offset);
    _engine.setPause(_voice!, false);
  }

  @override
  Duration get position {
    final voice = _voice;
    if (voice == null || !_engine.getIsValidVoiceHandle(voice)) {
      throw StateError('Metronome audio stopped unexpectedly');
    }
    return _engine.getPosition(voice);
  }

  @override
  void silence() {
    final voice = _voice;
    if (voice != null &&
        _engine.isInitialized &&
        _engine.getIsValidVoiceHandle(voice)) {
      _engine.setPause(voice, true);
    }
  }

  @override
  Future<void> clear() => _serialize(_clear);

  Future<void> _clear() async {
    final voice = _voice;
    final source = _source;
    _voice = null;
    _source = null;
    if (voice == null && source == null) return;
    if (!_engine.isInitialized) return;
    try {
      if (voice != null) await _engine.stop(voice);
    } finally {
      if (source != null) await _engine.disposeSource(source);
    }
  }

  @override
  Future<void> dispose() => _serialize(() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _clear();
    } finally {
      _clients--;
      if (_clients == 0 && _ownsEngine && _engine.isInitialized) {
        await _engine.deinitAsync();
        _ownsEngine = false;
      }
    }
  });
}
