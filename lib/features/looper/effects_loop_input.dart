import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../effects/effects_backend.dart';
import 'loop_audio.dart';

/// Taps the shared host after its effect chain, before monitor volume.
class EffectsLoopInput implements LoopInput {
  EffectsLoopInput(this.backend);

  final EffectsBackend backend;
  Timer? _timer;
  StreamController<Uint8List>? _stream;
  bool _reading = false;
  int _generation = 0;

  @override
  Future<List<InputDevice>> devices() async => [];

  @override
  Future<Stream<Uint8List>> start(InputDevice? device) async {
    await stop();
    await backend.send('loopStart');
    final generation = ++_generation;
    final stream = _stream = StreamController<Uint8List>();
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) async {
      if (_reading || generation != _generation) return;
      _reading = true;
      try {
        final result = await backend.send('loopRead');
        if (generation != _generation) return;
        final bytes = base64Decode(result['pcm'] as String);
        if (bytes.isNotEmpty) stream.add(bytes);
      } catch (error, stack) {
        if (generation != _generation) return;
        _timer?.cancel();
        stream.addError(error, stack);
      } finally {
        _reading = false;
      }
    });
    return stream.stream;
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    // Closing need not wait for a subscriber that is being cancelled.
    unawaited(stream.close());
    try {
      await backend.send('loopStop');
    } catch (_) {
      // The shared engine may already have exited during page disposal.
    }
  }

  @override
  Future<void> dispose() => stop();
}
