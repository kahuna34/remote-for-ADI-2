import 'package:adi2_remote/eq/eq_math.dart';
import 'package:adi2_remote/eq/eq_plot_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Logarithmische Skala hat alle Haupt- und Nebenlinien', () {
    expect(EqPlotScale.frequencyLabels, {
      20: '20',
      100: '100',
      1000: '1k',
      10000: '10k',
    });
    expect(EqPlotScale.minorFrequencies, [
      for (var f = 30; f <= 90; f += 10) f,
      for (var f = 200; f <= 900; f += 100) f,
      for (var f = 2000; f <= 9000; f += 1000) f,
      20000,
    ]);
    expect(freqToX(20), 0);
    expect(freqToX(20000), 1);
    expect(freqToX(200), closeTo(1 / 3, 1e-10));
  });

  test('Lineare Kurven und einzelne 12-dB-Punkte verwenden ±12', () {
    final scale = EqPlotScale.forShapes([]);
    expect(scale.range, 12);
    expect(scale.gains.map(scale.gainLabel), ['−12', '−6', '0', '+6', '+12']);
    expect(
      EqPlotScale.forShapes([const EqBandShape(FilterKind.peak, 1234, 12, 9.9)])
          .range,
      12,
    );
  });

  test('Überlagerte schmale Spitzen und Absenkungen erweitern auf ±20', () {
    for (final gain in [8.0, -8.0]) {
      final scale = EqPlotScale.forShapes([
        EqBandShape(FilterKind.peak, 1234, gain, 9.9),
        EqBandShape(FilterKind.peak, 1234, gain, 9.9),
      ]);
      expect(scale.range, 20);
      expect(scale.gains.map(scale.gainLabel), [
        '−20',
        '−12',
        '−6',
        '0',
        '+6',
        '+12',
        '+20',
      ]);
    }
    expect(
      EqPlotScale.forShapes([
        const EqBandShape(FilterKind.highPass, 1000, 0, 0.7),
      ]).range,
      20,
    );
    expect(EqPlotScale.forShapes([]).range, 12);
  });
}
