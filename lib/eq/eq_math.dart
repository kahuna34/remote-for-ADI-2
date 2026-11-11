// Frequenzgang der EQ-Bänder (RBJ-Audio-EQ-Cookbook-Biquads) zur Anzeige.

import 'dart:math' as math;

enum FilterKind { peak, lowShelf, highShelf, highPass, lowPass }

class Biquad {
  Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
  final double b0, b1, b2, a1, a2;

  /// Betrag in dB bei Frequenz [f] (Hz) und Abtastrate [fs].
  double magnitudeDb(double f, double fs) {
    final w = 2 * math.pi * f / fs;
    final c1 = math.cos(w), s1 = math.sin(w);
    final c2 = math.cos(2 * w), s2 = math.sin(2 * w);
    final nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
    final dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    final num = nr * nr + ni * ni, den = dr * dr + di * di;
    if (den <= 0 || num <= 0) return -120;
    return 10 * math.log(num / den) / math.ln10;
  }

  factory Biquad.design(
    FilterKind kind,
    double f0,
    double gainDb,
    double q,
    double fs,
  ) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * f0.clamp(10, fs * 0.45) / fs;
    final cw = math.cos(w0), sw = math.sin(w0);
    final alpha = sw / (2 * q);
    double b0, b1, b2, a0, a1, a2;
    switch (kind) {
      case FilterKind.peak:
        b0 = 1 + alpha * a;
        b1 = -2 * cw;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cw;
        a2 = 1 - alpha / a;
      case FilterKind.lowShelf:
        final sa = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) - (a - 1) * cw + sa);
        b1 = 2 * a * ((a - 1) - (a + 1) * cw);
        b2 = a * ((a + 1) - (a - 1) * cw - sa);
        a0 = (a + 1) + (a - 1) * cw + sa;
        a1 = -2 * ((a - 1) + (a + 1) * cw);
        a2 = (a + 1) + (a - 1) * cw - sa;
      case FilterKind.highShelf:
        final sa = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) + (a - 1) * cw + sa);
        b1 = -2 * a * ((a - 1) + (a + 1) * cw);
        b2 = a * ((a + 1) + (a - 1) * cw - sa);
        a0 = (a + 1) - (a - 1) * cw + sa;
        a1 = 2 * ((a - 1) - (a + 1) * cw);
        a2 = (a + 1) - (a - 1) * cw - sa;
      case FilterKind.highPass:
        b0 = (1 + cw) / 2;
        b1 = -(1 + cw);
        b2 = (1 + cw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
      case FilterKind.lowPass:
        b0 = (1 - cw) / 2;
        b1 = 1 - cw;
        b2 = (1 - cw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
    }
    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
  }
}

/// Ein Band für die Anzeige.
class EqBandShape {
  const EqBandShape(this.kind, this.freq, this.gainDb, this.q);
  final FilterKind kind;
  final double freq;
  final double gainDb;
  final double q;

  /// Hat Gain eine Wirkung? (Hoch-/Tiefpass nicht)
  bool get hasGain => kind != FilterKind.highPass && kind != FilterKind.lowPass;

  double responseDb(double f, {double fs = 192000}) =>
      Biquad.design(kind, freq, hasGain ? gainDb : 0, q, fs).magnitudeDb(f, fs);
}

double totalResponseDb(Iterable<EqBandShape> bands, double f) =>
    bands.fold(0.0, (s, b) => s + b.responseDb(f));

/// Logarithmische Frequenzachse 20 Hz … 20 kHz -> 0..1.
double freqToX(double f) => (math.log(f / 20) / math.log(1000)).clamp(0.0, 1.0);

double xToFreq(double x) => 20 * math.pow(1000, x.clamp(0.0, 1.0)).toDouble();
