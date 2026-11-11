import 'package:adi2_remote/eq/eq_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Peak: volle Verstärkung in der Mitte, neutral weit weg', () {
    const b = EqBandShape(FilterKind.peak, 1000, 6, 1.0);
    expect(b.responseDb(1000), closeTo(6, 0.05));
    expect(b.responseDb(20), closeTo(0, 0.1));
    expect(b.responseDb(20000), closeTo(0, 0.2));
  });

  test('Low-Shelf hebt tief an, lässt hoch unverändert', () {
    const b = EqBandShape(FilterKind.lowShelf, 100, 6, 0.7);
    expect(b.responseDb(20), closeTo(6, 0.3));
    expect(b.responseDb(10000), closeTo(0, 0.1));
  });

  test('High-Shelf hebt hoch an', () {
    const b = EqBandShape(FilterKind.highShelf, 6500, -4, 0.7);
    expect(b.responseDb(20000), closeTo(-4, 0.5));
    expect(b.responseDb(100), closeTo(0, 0.1));
  });

  test('Hochpass (12 dB/Oktave) dämpft eine Oktave darunter um ca. 12 dB', () {
    const b = EqBandShape(FilterKind.highPass, 200, 0, 0.707);
    expect(b.responseDb(200), closeTo(-3, 0.3));
    expect(b.responseDb(50), lessThan(-20));
    expect(b.responseDb(5000), closeTo(0, 0.1));
  });

  test('Bänder addieren sich in dB', () {
    const a = EqBandShape(FilterKind.peak, 1000, 3, 1);
    const b = EqBandShape(FilterKind.peak, 1000, 3, 1);
    expect(totalResponseDb([a, b], 1000), closeTo(6, 0.05));
  });

  test('Frequenzachse ist logarithmisch und umkehrbar', () {
    expect(freqToX(20), 0);
    expect(freqToX(20000), closeTo(1, 1e-9));
    expect(xToFreq(freqToX(1234)), closeTo(1234, 0.01));
  });
}
