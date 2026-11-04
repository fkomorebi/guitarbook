import 'package:flutter_test/flutter_test.dart';
import 'package:guitarbook/features/drums/drum_pattern.dart';

/// 4/4 预设扩到 5 轨时，底鼓、军鼓、踩镲三行必须保持原样。
const _legacyRows = <String, List<List<int>>>{
  '摇滚': [
    [0, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '放克': [
    [0, 3, 8, 10],
    [4, 12, 15],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '布鲁斯': [
    [0, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '流行': [
    [0, 6, 8],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '民谣': [
    [0, 8],
    [4, 12],
    [0, 4, 8, 12],
  ],
  '朋克': [
    [0, 2, 8, 10],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '金属': [
    [0, 2, 3, 6, 8, 10, 11, 14],
    [4, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '迪斯科': [
    [0, 4, 8, 12],
    [4, 12],
    [2, 6, 10, 14],
  ],
  '雷鬼': [
    [8],
    [8],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
  '嘻哈': [
    [0, 3, 10],
    [4, 12],
    [0, 2, 4, 6, 7, 8, 10, 12, 14, 15],
  ],
  '爵士摇摆': [
    [0, 8],
    [4, 12],
    [0, 4, 6, 8, 12, 14],
  ],
  '拉丁': [
    [0, 6, 8, 14],
    [0, 6, 12],
    [0, 2, 4, 6, 8, 10, 12, 14],
  ],
};

List<List<bool>> _matrix(DrumPreset preset) => [
  for (final row in preset.hits)
    List.generate(preset.meter.steps, row.contains),
];

void main() {
  test('style presets have valid distinct rhythms', () {
    expect(drumPresets, hasLength(22));
    expect(drumPresets.map((p) => p.name).toSet(), hasLength(22));
    for (final preset in drumPresets) {
      expect(preset.hits, hasLength(drumTrackNames.length));
      expect(preset.swing, inInclusiveRange(0, 60));
      for (final row in preset.hits) {
        expect(row.toSet(), hasLength(row.length));
        expect(
          row.every((step) => step >= 0 && step < preset.meter.steps),
          isTrue,
          reason: '${preset.name} 超出 ${preset.meter.label} 的步数',
        );
      }
    }
    // 同一拍号内的节奏不能完全相同。
    for (final meter in drumMeters) {
      final presets = drumPresetsFor(meter);
      final rhythms = presets.map((p) => '${p.hits}:${p.swing}').toSet();
      expect(rhythms, hasLength(presets.length), reason: meter.label);
    }
  });

  test('4/4 presets keep their original kick snare and hat rows', () {
    final legacy = drumPresetsFor(const DrumMeter(4, 4));
    expect(legacy, hasLength(12));
    for (final preset in legacy) {
      final rows = _legacyRows[preset.name];
      expect(rows, isNotNull, reason: preset.name);
      expect(preset.hits[0], rows![0], reason: '${preset.name} 底鼓');
      expect(preset.hits[1], rows[1], reason: '${preset.name} 军鼓');
      expect(preset.hits[2], rows[2], reason: '${preset.name} 踩镲');
    }
  });

  test('every meter ships its own preset set', () {
    expect(drumPresetsFor(const DrumMeter(4, 4)), hasLength(12));
    for (final meter in drumMeters.skip(1)) {
      expect(drumPresetsFor(meter), hasLength(2), reason: meter.label);
    }
    for (final meter in drumMeters) {
      expect(drumDefaultPreset(meter).meter, meter);
    }
  });

  test('presets render finite bounded loops at all tempo limits', () {
    for (final bpm in [30, 100, 137, 240]) {
      for (final preset in drumPresets) {
        final pattern = renderDrums(
          bpm,
          _matrix(preset),
          List.filled(drumTrackNames.length, false),
          preset.swing,
          meter: preset.meter,
        );
        expect(pattern.beats, preset.meter.beats);
        expect(
          pattern.samples.length,
          pattern.framesPerBeat * preset.meter.beats,
        );
        // 一拍在 x/4 是四分音符、在 x/8 是八分音符，BPM 始终是每分钟四分音符数。
        expect(
          pattern.sampleRate * 60,
          pattern.framesPerBeat *
              bpm *
              (preset.meter.denominator == 8 ? 2 : 1),
        );
        expect(pattern.samples.every((v) => v.isFinite && v.abs() < 1), isTrue);
        expect(pattern.samples.any((v) => v.abs() > .05), isTrue);
        expect(pattern.toWav().length, 44 + pattern.samples.length * 2);
      }
    }
  });

  test('rendering is deterministic', () {
    final preset = drumDefaultPreset(const DrumMeter(5, 4));
    final first = renderDrums(
      100,
      _matrix(preset),
      List.filled(drumTrackNames.length, false),
      preset.swing,
      meter: preset.meter,
    );
    final second = renderDrums(
      100,
      _matrix(preset),
      List.filled(drumTrackNames.length, false),
      preset.swing,
      meter: preset.meter,
    );
    expect(first.samples.length, second.samples.length);
    for (var i = 0; i < first.samples.length; i++) {
      expect(first.samples[i], second.samples[i]);
    }
  });

  test('every track can be muted on its own', () {
    for (var track = 0; track < drumTrackNames.length; track++) {
      final hits = [
        for (var t = 0; t < drumTrackNames.length; t++)
          List.generate(16, (step) => t == track && step == 0),
      ];
      final loud = renderDrums(100, hits, List.filled(5, false), 0);
      final muted = [
        for (var t = 0; t < drumTrackNames.length; t++) t == track,
      ];
      final quiet = renderDrums(100, hits, muted, 0);
      expect(
        loud.samples.any((v) => v.abs() > .05),
        isTrue,
        reason: '${drumTrackNames[track]} 应该有声音',
      );
      expect(
        quiet.samples.every((v) => v == 0),
        isTrue,
        reason: '${drumTrackNames[track]} 静音后应该无声',
      );
    }
  });

  test('swing delays off eighths and mute removes all sound', () {
    expect(drumStepFrame(0, 24000, 33), 0);
    expect(drumStepFrame(2, 24000, 33), 15960);
    expect(drumStepFrame(4, 24000, 33), 24000);
    final pattern = renderDrums(
      100,
      List.generate(3, (_) => List.filled(16, true)),
      [true, true, true],
      60,
    );
    expect(pattern.samples.every((v) => v == 0), isTrue);
  });
}
