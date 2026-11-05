import 'dart:math' as math;
import 'dart:typed_data';

/// 音级名，C=0。
const List<String> pitchClassNames = <String>[
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];

/// 和弦质量模板：相对根音的半音数集合。
const Map<String, List<int>> chordQualityTemplates = <String, List<int>>{
  'maj': <int>[0, 4, 7],
  'min': <int>[0, 3, 7],
  'dim': <int>[0, 3, 6],
  'aug': <int>[0, 4, 8],
  'sus4': <int>[0, 5, 7],
  '6': <int>[0, 4, 7, 9],
  'm7': <int>[0, 3, 7, 10],
  'maj7': <int>[0, 4, 7, 11],
  '7': <int>[0, 4, 7, 10],
  'm7b5': <int>[0, 3, 6, 10],
};

/// 质量 id → 中文标签。
const Map<String, String> chordQualityLabels = <String, String>{
  'maj': '大',
  'min': '小',
  'dim': '减',
  'aug': '增',
  'sus4': '挂四',
  '6': '六',
  'm7': '小七',
  'maj7': '大七',
  '7': '属七',
  'm7b5': '半减七',
};

/// 一次和弦识别结果。
class ChordDetection {
  const ChordDetection({
    required this.root,
    required this.quality,
    required this.confidence,
    required this.intervals,
  });

  final int root;
  final String quality;
  final double confidence;
  final List<int> intervals;

  /// 质量的中文标签，例如「属七」。
  String get qualityLabel => chordQualityLabels[quality] ?? quality;

  /// 展示名，例如「C 大和弦」「A 小和弦」。
  String get name => '${pitchClassNames[root]}$qualityLabel和弦';

  /// 和弦包含的绝对音级，例如 C 大和弦 → [0, 4, 7]。
  List<int> get pitchClasses =>
      intervals.map((int interval) => (root + interval) % 12).toList();
}

/// 从单声道 PCM 浮点样本中识别和弦；无法给出可信结果时返回 null。
///
/// [samples] 是最近一段音频窗口（调用方会传入 4096 个样本），
/// [sampleRate] 是采样率（工作台传入的输入固定为 48000）。
ChordDetection? detectChord(
  Float32List samples, {
  int sampleRate = 48000,
  double minConfidence = 0.35,
}) {
  if (samples.isEmpty) return null;
  if (_rms(samples) < _rmsFloor) return null;
  final spectrum = _spectrum(samples, sampleRate);
  if (spectrum.maxMagnitude <= 0) return null;
  if (_flatness(spectrum.magnitudes) > _flatnessLimit) return null;
  final peaks = _findPeaks(spectrum.magnitudes, spectrum.binHz);
  if (peaks.isEmpty) return null;
  final evidence = _harmonicEvidence(peaks, spectrum.maxMagnitude, sampleRate);
  final best = _bestHypothesis(evidence, peaks, spectrum.maxMagnitude);
  if (best == null) return null;
  if (best.score < minConfidence) return null;
  final intervals = chordQualityTemplates[best.quality]!;
  return ChordDetection(
    root: best.root,
    quality: best.quality,
    confidence: best.score.clamp(0.0, 1.0),
    intervals: List<int>.unmodifiable(intervals),
  );
}

/// FFT 点数，48 kHz 下约 11.7 Hz 一个频点。
const int _fftSize = 4096;

/// 参与识别的最低 MIDI 音高（E2）。
const int _minMidi = 40;

/// 参与识别的最高 MIDI 音高（C6）。
const int _maxMidi = 84;

/// 每个音高最多考虑的谐波次数。
const int _harmonicCount = 3;

/// 谐波权重：基频最强，高次谐波依次减弱。
const List<double> _harmonicWeights = <double>[1.0, 0.55, 0.4];

/// 谱峰匹配容差（音分）。
const double _centsTolerance = 35;

/// 低频区谱峰与基频的允许偏差（音分），用于确认低音确实存在。
const double _lowSupportTolerance = 250;

/// 谱峰重叠（两个音混在一起）时的容忍偏差（音分）。
const double _blendTolerance = 180;

/// 只校验这个频率以上的谱峰，更低的频率在 4096 点 FFT 下无法分辨。
const double _verifiableFrequency = 200;

/// 幅度对数压缩系数，抑制高次谐波与高八度的压制。
const double _logScale = 10;

/// 在场音高的权重。
const double _presentWeight = 0.8;

/// 缺失音高的惩罚权重。
const double _absentPenalty = 0.8;

/// 未被解释的谱峰权重。
const double _unexplainedWeight = 0.4;

/// 基频落在低频区、无法直接校验时的折损比例。
const double _unverifiedWeight = 0.04;

/// 静音判定阈值：RMS 低于该值直接返回 null。
const double _rmsFloor = 0.002;

/// 谱平坦度上限：白噪声的平坦度远高于和弦，越过上限判定为噪声。
const double _flatnessLimit = 0.4;

/// 一个频谱峰。
class _Peak {
  const _Peak(this.frequency, this.magnitude);

  final double frequency;
  final double magnitude;
}

/// 频谱数据。
class _Spectrum {
  const _Spectrum(this.magnitudes, this.binHz, this.maxMagnitude);

  final Float64List magnitudes;
  final double binHz;
  final double maxMagnitude;
}

/// 单次谐波的证据：[目标频率, 权重, 命中峰值序号（未命中为 -1）]。
class _HarmonicHit {
  const _HarmonicHit(this.frequency, this.weight, this.peakIndex);

  final double frequency;
  final double weight;
  final int peakIndex;
}

/// 单个候选音高的谐波证据。
class _NoteEvidence {
  const _NoteEvidence(
    this.midi,
    this.hits,
    this.fundamentalMatched,
    this.lowSupported,
  );

  final int midi;
  final List<_HarmonicHit> hits;

  /// 基频处是否找到谱峰。
  final bool fundamentalMatched;

  /// 低频区是否有谱峰落在基频附近（说明该音确实在演奏）。
  final bool lowSupported;
}

/// 一个和弦假设的匹配结果。
class _Hypothesis {
  const _Hypothesis(
    this.root,
    this.quality,
    this.rootMidi,
    this.score,
    this.presentNotes,
  );

  final int root;
  final String quality;
  final int rootMidi;
  final double score;
  final int presentNotes;
}

/// 单个假设的得分与在场音高数。
class _Score {
  const _Score(this.score, this.present);

  final double score;
  final int present;
}

/// MIDI 音高转频率（A4 = 440 Hz）。
double midiToFrequency(int midi) =>
    440 * math.pow(2, (midi - 69) / 12).toDouble();

/// 计算窗口的均方根值。
double _rms(Float32List samples) {
  var sum = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i];
    sum += v * v;
  }
  return math.sqrt(sum / samples.length);
}

/// 加 Hann 窗并做 FFT，返回幅度谱。
_Spectrum _spectrum(Float32List samples, int sampleRate) {
  final used = math.min(samples.length, _fftSize);
  final start = samples.length - used;
  final re = Float64List(_fftSize);
  final im = Float64List(_fftSize);
  for (var i = 0; i < used; i++) {
    final window = used > 1
        ? 0.5 * (1 - math.cos(2 * math.pi * i / (used - 1)))
        : 1.0;
    re[i] = samples[start + i] * window;
  }
  _fft(re, im);
  final half = _fftSize ~/ 2;
  final magnitudes = Float64List(half + 1);
  var maxMagnitude = 0.0;
  for (var k = 0; k <= half; k++) {
    final v = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    magnitudes[k] = v;
    if (v > maxMagnitude) maxMagnitude = v;
  }
  return _Spectrum(magnitudes, sampleRate / _fftSize, maxMagnitude);
}

/// 单遍迭代式 radix-2 FFT（原地）。
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      final tmpRe = re[i];
      re[i] = re[j];
      re[j] = tmpRe;
      final tmpIm = im[i];
      im[i] = im[j];
      im[j] = tmpIm;
    }
  }
  for (var length = 2; length <= n; length <<= 1) {
    final angle = 2 * math.pi / length;
    final stepRe = math.cos(angle);
    final stepIm = math.sin(angle);
    final half = length >> 1;
    for (var base = 0; base < n; base += length) {
      var curRe = 1.0;
      var curIm = 0.0;
      for (var k = 0; k < half; k++) {
        final aRe = re[base + k];
        final aIm = im[base + k];
        final bRe = re[base + k + half];
        final bIm = im[base + k + half];
        final vRe = bRe * curRe - bIm * curIm;
        final vIm = bRe * curIm + bIm * curRe;
        re[base + k] = aRe + vRe;
        im[base + k] = aIm + vIm;
        re[base + k + half] = aRe - vRe;
        im[base + k + half] = aIm - vIm;
        final nextRe = curRe * stepRe - curIm * stepIm;
        curIm = curRe * stepIm + curIm * stepRe;
        curRe = nextRe;
      }
    }
  }
}

/// 谱平坦度：几何平均与算术平均之比，越接近 1 越像噪声。
double _flatness(Float64List magnitudes) {
  var sum = 0.0;
  var logSum = 0.0;
  var count = 0;
  for (var k = 2; k < magnitudes.length; k++) {
    final v = magnitudes[k] + 1e-12;
    sum += v;
    logSum += math.log(v);
    count++;
  }
  if (count == 0 || sum <= 0) return 1.0;
  return math.exp(logSum / count) / (sum / count);
}

/// 提取谱峰并做抛物线插值细化频率。
List<_Peak> _findPeaks(Float64List magnitudes, double binHz) {
  final peaks = <_Peak>[];
  var maxMagnitude = 0.0;
  for (var k = 1; k < magnitudes.length; k++) {
    if (magnitudes[k] > maxMagnitude) maxMagnitude = magnitudes[k];
  }
  if (maxMagnitude <= 0) return peaks;
  final limit = maxMagnitude * 0.01;
  for (var k = 2; k < magnitudes.length - 2; k++) {
    final v = magnitudes[k];
    if (v < limit) continue;
    if (v < magnitudes[k - 1] || v < magnitudes[k + 1]) continue;
    final left = magnitudes[k - 1];
    final right = magnitudes[k + 1];
    final denominator = left - 2 * v + right;
    var shift = 0.0;
    if (denominator.abs() > 1e-12) {
      shift = 0.5 * (left - right) / denominator;
      if (shift.abs() > 0.5) shift = 0.0;
    }
    peaks.add(_Peak((k + shift) * binHz, v));
  }
  return peaks;
}

/// 计算目标频率与某个谱峰的音分偏差。
double _cents(double target, double frequency) =>
    1200 * math.log(frequency / target) / math.ln2;

/// 为每个候选音高寻找各次谐波对应的谱峰。
List<_NoteEvidence> _harmonicEvidence(
  List<_Peak> peaks,
  double maxMagnitude,
  int sampleRate,
) {
  final evidence = <_NoteEvidence>[];
  for (var midi = _minMidi; midi <= _maxMidi; midi++) {
    final hits = <_HarmonicHit>[];
    final fundamental = midiToFrequency(midi);
    for (var h = 1; h <= _harmonicCount; h++) {
      final target = fundamental * h;
      if (target >= sampleRate / 2) break;
      // 太低的频率在当前窗长下无法分辨，既不奖励也不惩罚。
      if (target < _verifiableFrequency) continue;
      var bestCents = double.infinity;
      var bestIndex = -1;
      for (var i = 0; i < peaks.length; i++) {
        final cents = _cents(target, peaks[i].frequency).abs();
        if (cents < bestCents) {
          bestCents = cents;
          bestIndex = i;
        }
      }
      final matched = bestCents <= _centsTolerance;
      hits.add(
        _HarmonicHit(target, _harmonicWeights[h - 1], matched ? bestIndex : -1),
      );
    }
    var fundamentalMatched = false;
    var lowSupported = false;
    for (var i = 0; i < peaks.length; i++) {
      final peak = peaks[i];
      final cents = _cents(fundamental, peak.frequency).abs();
      if (cents <= _centsTolerance) {
        fundamentalMatched = true;
      } else if (peak.frequency < _verifiableFrequency &&
          cents <= _lowSupportTolerance) {
        lowSupported = true;
      }
    }
    evidence.add(_NoteEvidence(midi, hits, fundamentalMatched, lowSupported));
  }
  return evidence;
}

/// 在所有「根音音高 × 质量」组合中挑出最可信的和弦。
_Hypothesis? _bestHypothesis(
  List<_NoteEvidence> evidence,
  List<_Peak> peaks,
  double maxMagnitude,
) {
  _Hypothesis? best;
  for (final quality in chordQualityTemplates.keys) {
    final intervals = chordQualityTemplates[quality]!;
    final maxInterval = intervals.reduce(math.max);
    for (
      var rootMidi = _minMidi;
      rootMidi + maxInterval <= _maxMidi;
      rootMidi++
    ) {
      final score = _scoreHypothesis(
        evidence,
        peaks,
        maxMagnitude,
        intervals,
        rootMidi,
      );
      if (score == null) continue;
      final candidate = _Hypothesis(
        rootMidi % 12,
        quality,
        rootMidi,
        score.score,
        score.present,
      );
      if (_better(candidate, best)) best = candidate;
    }
  }
  return best;
}

/// 计算一个假设对频谱的解释程度。
_Score? _scoreHypothesis(
  List<_NoteEvidence> evidence,
  List<_Peak> peaks,
  double maxMagnitude,
  List<int> intervals,
  int rootMidi,
) {
  final predictions = <_HarmonicHit>[];
  var present = 0;
  var unverified = 0;
  for (final interval in intervals) {
    final midi = rootMidi + interval;
    if (midi < _minMidi || midi > _maxMidi) return null;
    final item = evidence[midi - _minMidi];
    final harmonicMatched = item.hits.any((_HarmonicHit hit) {
      return hit.peakIndex >= 0;
    });
    if (!item.fundamentalMatched && !(harmonicMatched && item.lowSupported)) {
      continue;
    }
    present++;
    if (midiToFrequency(midi) < _verifiableFrequency) unverified++;
    predictions.addAll(item.hits);
  }
  if (predictions.isEmpty) return null;
  predictions.sort((_HarmonicHit a, _HarmonicHit b) {
    return a.frequency.compareTo(b.frequency);
  });
  var matchedWeight = 0.0;
  var missingWeight = 0.0;
  final explained = <int>{};
  var index = 0;
  while (index < predictions.length) {
    var weight = predictions[index].weight;
    var bestPeak = -1;
    final group = <_HarmonicHit>[predictions[index]];
    var next = index + 1;
    while (next < predictions.length &&
        _sameTarget(predictions[index], predictions[next])) {
      group.add(predictions[next]);
      next++;
    }
    for (final hit in group) {
      if (hit.weight > weight) weight = hit.weight;
      if (hit.peakIndex >= 0) {
        explained.add(hit.peakIndex);
        if (bestPeak < 0 ||
            peaks[hit.peakIndex].magnitude > peaks[bestPeak].magnitude) {
          bestPeak = hit.peakIndex;
        }
      }
    }
    if (bestPeak >= 0) {
      final ratio = peaks[bestPeak].magnitude / maxMagnitude;
      matchedWeight += weight * math.log(1 + _logScale * ratio);
    } else if (!_blendedWith(peaks, explained, group)) {
      missingWeight += weight;
    }
    index = next;
  }
  // 频谱里没有被假设解释的谱峰也要扣分。
  var unexplainedWeight = 0.0;
  for (var i = 0; i < peaks.length; i++) {
    if (explained.contains(i)) continue;
    if (peaks[i].frequency < _verifiableFrequency) continue;
    unexplainedWeight +=
        _unexplainedWeight *
        math.log(1 + _logScale * peaks[i].magnitude / maxMagnitude);
  }
  final absent = intervals.length - present;
  final numerator = matchedWeight + _presentWeight * present;
  final denominator =
      matchedWeight +
      missingWeight +
      _presentWeight * intervals.length +
      _absentPenalty * absent +
      (unverified > 0 ? _unverifiedWeight * matchedWeight : 0) +
      unexplainedWeight;
  if (denominator <= 0) return null;
  return _Score(numerator / denominator, present);
}

/// 判断该组预测是否与已有谱峰重叠（谱峰混叠时不再额外扣分）。
bool _blendedWith(
  List<_Peak> peaks,
  Set<int> explained,
  List<_HarmonicHit> group,
) {
  for (final hit in group) {
    for (var i = 0; i < peaks.length; i++) {
      final cents =
          (1200 * math.log(peaks[i].frequency / hit.frequency) / math.ln2)
              .abs();
      if (cents <= _blendTolerance) return true;
    }
  }
  return false;
}

/// 判断两条预测是否落在同一个谱峰上。
bool _sameTarget(_HarmonicHit a, _HarmonicHit b) {
  final ratio = a.frequency / b.frequency;
  return (ratio - 1).abs() < 0.02;
}

/// 比较两个假设的优劣。
bool _better(_Hypothesis candidate, _Hypothesis? best) {
  if (best == null) return true;
  if (candidate.score > best.score + 1e-9) return true;
  if (candidate.score < best.score - 1e-9) return false;
  if (candidate.presentNotes != best.presentNotes) {
    return candidate.presentNotes > best.presentNotes;
  }
  return candidate.rootMidi < best.rootMidi;
}
