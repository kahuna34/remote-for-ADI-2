import 'dart:math' as math;

import 'package:adi2_remote/analyzer/analyzer_dsp.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> _sine(int frames, double hz, int rate, {double amplitude = .5}) =>
    [
      for (var i = 0; i < frames; i++)
        for (var ch = 0; ch < 2; ch++)
          amplitude * math.sin(2 * math.pi * hz * i / rate),
    ];

void main() {
  test('30 fps analysis halves the frames and keeps one second of time', () {
    const rate = 48000;
    final audio = _sine(rate, 1000, rate);
    final full = AnalyzerDsp().add(audio, rate);
    final half = AnalyzerDsp(frameRate: 30).add(audio, rate);
    expect(full, hasLength(60));
    expect(half, hasLength(30));
    final seconds = half.fold<double>(0, (s, f) => s + f.seconds);
    expect(seconds, closeTo(1, 1e-9));
  });

  test('30 fps analysis shows the same tone level and band', () {
    const rate = 48000;
    final audio = _sine(rate, 1000, rate);
    final full = AnalyzerDsp().add(audio, rate).last;
    final half = AnalyzerDsp(frameRate: 30).add(audio, rate).last;
    for (var ch = 0; ch < 2; ch++) {
      expect(half.rms[ch], closeTo(full.rms[ch], .05));
      expect(half.peak[ch], closeTo(full.peak[ch], .05));
    }
    int loudest(List<double> v) => List.generate(
      v.length,
      (i) => i,
    ).reduce((a, b) => v[a] >= v[b] ? a : b);
    expect(loudest(half.bandLevels), loudest(full.bandLevels));
    expect(loudest(half.spectrum), loudest(full.spectrum));
  });
}
