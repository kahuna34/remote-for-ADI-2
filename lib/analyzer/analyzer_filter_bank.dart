import 'dart:math' as math;

import 'analyzer_dsp.dart';

/// Fourth-order bandpass from a second-order Butterworth lowpass prototype.
/// Prewarp the IEC base-10 edges, anchor the nominal centre and use the narrower
/// allowed bandwidth. This is an engineering filter bank, not a claim of
/// IEC 61260 instrument certification.
class AnalyzerBandFilter {
  AnalyzerBandFilter(double centre, double ratio, int rate) {
    final lo = math.tan(math.pi * centre / ratio / rate);
    final hi = math.tan(
      math.pi * math.min(centre * ratio, rate * 0.499) / rate,
    );
    final middle = math.tan(math.pi * centre / rate);
    // Keep the resonance at the nominal digital centre, including near
    // Nyquist; independently warped edges otherwise displace the passband.
    final bandwidth = math.min(
      (middle * middle - lo * lo) / lo,
      (hi * hi - middle * middle) / hi,
    );
    final real = -bandwidth / math.sqrt2;
    final imaginary = bandwidth / math.sqrt2;
    final dr = real * real - imaginary * imaginary - 4 * middle * middle;
    final di = 2 * real * imaginary;
    final magnitude = math.sqrt(dr * dr + di * di);
    final sr = math.sqrt(math.max(0, (magnitude + dr) / 2));
    final si = -math.sqrt(math.max(0, (magnitude - dr) / 2));
    for (final sign in [-1, 1]) {
      final pr = (real + sign * sr) / 2;
      final pi = (imaginary + sign * si) / 2;
      final denominator = (1 - pr) * (1 - pr) + pi * pi;
      final zr = (1 - pr * pr - pi * pi) / denominator;
      final zi = 2 * pi / denominator;
      _sections.add(_BandBiquad(-2 * zr, zr * zr + zi * zi));
    }
    final w = 2 * math.pi * centre / rate;
    var gain = 1.0;
    for (final s in _sections) {
      final re = 1 + s.a1 * math.cos(w) + s.a2 * math.cos(2 * w);
      final im = -s.a1 * math.sin(w) - s.a2 * math.sin(2 * w);
      gain *= 2 * math.sin(w).abs() / math.sqrt(re * re + im * im);
    }
    _gain = 1 / gain;
  }
  final List<_BandBiquad> _sections = [];
  late final double _gain;
  double process(double value, int channel) {
    for (final section in _sections) {
      value = section.process(value, channel);
    }
    return value * _gain;
  }
}

class _BandBiquad {
  _BandBiquad(this.a1, this.a2);
  final double a1, a2;
  final z1 = [0.0, 0.0], z2 = [0.0, 0.0];
  double process(double input, int channel) {
    final output = input + z1[channel];
    z1[channel] = -a1 * output + z2[channel];
    z2[channel] = -input - a2 * output;
    return output;
  }
}

/// Continuous stereo power detection with 5 ms integration. A unity-gain
/// allpass supplies a quadrature signal at each centre, removing the twice-tone
/// RMS ripple without a slow bass integrator. The RMS-to-sine reference factor
/// 2 makes a full-scale centre sine read 0 dB in its band.
/// Max-L/R preserves hard-panned signals and opposite-polarity stereo.
class AnalyzerFilterBank {
  AnalyzerFilterBank(this.rate, this.resolution)
    : filters = List.generate(
        resolution.count,
        (i) => AnalyzerBandFilter(
          resolution.centre(i),
          resolution.edgeRatio,
          rate,
        ),
      ),
      _power = List.generate(resolution.count, (_) => [0.0, 0.0]),
      _quadrature = List.generate(resolution.count, (_) => [0.0, 0.0]),
      _allpass = List.generate(resolution.count, (i) {
        final t = math.tan(math.pi * resolution.centre(i) / rate);
        return (t - 1) / (t + 1);
      }),
      _alpha = 1 - math.exp(-1 / (rate * 0.005));
  final int rate;
  final AnalyzerBandResolution resolution;
  final List<AnalyzerBandFilter> filters;
  final List<List<double>> _power, _quadrature;
  final List<double> _allpass;
  final double _alpha;

  void process(double left, double right) {
    for (var band = 0; band < filters.length; band++) {
      for (var ch = 0; ch < 2; ch++) {
        final v = filters[band].process(ch == 0 ? left : right, ch);
        final q = _allpass[band] * v + _quadrature[band][ch];
        _quadrature[band][ch] = v - _allpass[band] * q;
        _power[band][ch] += _alpha * ((v * v + q * q) / 2 - _power[band][ch]);
      }
    }
  }

  List<double> get levels => _power
      .map((p) => amplitudeDb(math.sqrt(2 * math.max(p[0], p[1]))))
      .toList();
}

/// Meters run independently of either FFT window or display preset.
class AnalyzerMeters {
  AnalyzerMeters(int rate)
    : _alpha = 1 - math.exp(-1 / (rate * 0.3)),
      _peakFactor = math.pow(10, -(20 / 1.5) / (20 * rate)).toDouble();
  final double _alpha, _peakFactor;
  final _power = [0.0, 0.0], _peak = [0.0, 0.0];
  void process(double left, double right) {
    for (var ch = 0; ch < 2; ch++) {
      final value = ch == 0 ? left : right;
      _power[ch] += _alpha * (value * value - _power[ch]);
      _peak[ch] = math.max(value.abs(), _peak[ch] * _peakFactor);
    }
  }

  List<double> get peak => _peak.map(amplitudeDb).toList();
  List<double> get rms => _power.map((p) => amplitudeDb(math.sqrt(p))).toList();
}
