import 'dart:math' as math;

const guitarStrings = [
  (label: '6 弦 E2', frequency: 82.4069),
  (label: '5 弦 A2', frequency: 110.0),
  (label: '4 弦 D3', frequency: 146.8324),
  (label: '3 弦 G3', frequency: 195.9977),
  (label: '2 弦 B3', frequency: 246.9417),
  (label: '1 弦 E4', frequency: 329.6276),
];

double centsBetween(double frequency, double target) =>
    1200 * math.log(frequency / target) / math.ln2;

/// YIN cumulative mean normalized difference; input is mono normalized PCM.
double? detectPitch(List<double> samples, {int sampleRate = 22050}) {
  final maxLag = math.min(sampleRate ~/ 46, samples.length ~/ 2 - 1);
  if (maxLag < 3) return null;
  final mean = samples.reduce((a, b) => a + b) / samples.length;
  final energy = samples.fold<double>(
    0,
    (sum, x) => sum + (x - mean) * (x - mean),
  );
  if (math.sqrt(energy / samples.length) < 0.003) return null;
  final difference = List<double>.filled(maxLag + 1, 1);
  var cumulative = 0.0;
  final window = samples.length - maxLag;
  for (var lag = 1; lag <= maxLag; lag++) {
    var sum = 0.0;
    for (var i = 0; i < window; i++) {
      final delta = samples[i] - samples[i + lag];
      sum += delta * delta;
    }
    cumulative += sum;
    difference[lag] = cumulative == 0 ? 1 : sum * lag / cumulative;
  }
  for (var lag = sampleRate ~/ 1100; lag < maxLag - 1; lag++) {
    if (difference[lag] >= 0.15) continue;
    while (lag + 1 < maxLag && difference[lag + 1] < difference[lag]) {
      lag++;
    }
    if (lag >= maxLag) return null;
    final left = difference[lag - 1];
    final center = difference[lag];
    final right = difference[lag + 1];
    final denominator = left - 2 * center + right;
    final offset = denominator == 0 ? 0.0 : 0.5 * (left - right) / denominator;
    return sampleRate / (lag + offset);
  }
  return null;
}
