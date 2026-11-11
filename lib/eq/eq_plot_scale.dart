import 'eq_math.dart';

/// Gemeinsame Skala für Live-EQ und Preset-Editor.
class EqPlotScale {
  const EqPlotScale(this.range);
  final double range;

  static const frequencyLabels = {
    20: '20',
    100: '100',
    1000: '1k',
    10000: '10k',
  };
  static final minorFrequencies = <int>[
    for (final decade in [10, 100, 1000])
      for (var digit = 2; digit <= 9; digit++)
        if (decade * digit > 20) decade * digit,
    20000,
  ];

  List<double> get gains => [
    if (range > 12) -range,
    -12,
    -6,
    0,
    6,
    12,
    if (range > 12) range,
  ];

  String gainLabel(double gain) =>
      gain == 0 ? '0' : '${gain > 0 ? '+' : '−'}${gain.abs().round()}';

  factory EqPlotScale.forShapes(Iterable<EqBandShape> shapes) {
    final active = shapes.toList();
    // Bandfrequenzen zusätzlich prüfen, damit schmale Spitzen und Punkte
    // zwischen den Abtaststellen ebenfalls den Bereich erweitern.
    final frequencies = [
      for (var n = 0; n <= 600; n++) xToFreq(n / 600),
      for (final shape in active) shape.freq,
    ];
    final expanded = frequencies.any(
      (f) => totalResponseDb(active, f).abs() > 12.000001,
    );
    return EqPlotScale(expanded ? 20 : 12);
  }
}
