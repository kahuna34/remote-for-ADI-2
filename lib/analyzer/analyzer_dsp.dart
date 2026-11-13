import 'dart:math' as math;
import 'dart:typed_data';

import 'analyzer_filter_bank.dart';

/// Independent of capture/UI so later views can consume the same analysis frames.
enum AnalyzerView { spectrum }

enum AnalyzerBallistics { fast, medium, slow }

/// Log-spaced ISO centres from nominal 25 Hz through 20 kHz.
enum AnalyzerBandResolution {
  third(3),
  sixth(6),
  twelfth(12);

  const AnalyzerBandResolution(this.bandsPerOctave);
  final int bandsPerOctave;
  int get count => 29 * bandsPerOctave ~/ 3 + 1;
  double centre(int band) =>
      (1000 * math.pow(10, (band * 3 / bandsPerOctave - 16) / 10)).toDouble();
  double get edgeRatio => math.pow(10, 0.15 / bandsPerOctave).toDouble();
}

/// Keep physical FFT durations similar at high USB sample rates.
int analyzerFastSize(int sampleRate) {
  var size = 2048;
  while (sampleRate / size > 48000 / 2048) {
    size *= 2;
  }
  return size;
}

int analyzerBassSize(int sampleRate) => analyzerFastSize(sampleRate) * 4;
double analyzerBassLimit(int sampleRate) => 300;

const analyzerFloor = -120.0;
double amplitudeDb(double value) => value <= 0
    ? analyzerFloor
    : (20 * math.log(value) / math.ln10).clamp(analyzerFloor, 12).toDouble();
double logFrequency(double hz) =>
    (math.log(hz.clamp(20, 20000) / 20) / math.log(1000));
double frequencyAt(double x) => (20 * math.pow(1000, x.clamp(0, 1))).toDouble();

class AnalyzerFrame {
  const AnalyzerFrame({
    required this.sampleRate,
    required this.spectrum,
    required this.peak,
    required this.rms,
    required this.clipped,
    this.seconds = 1 / 60,
    this.spectrumBinHz = 0,
    this.logSpectrum = false,
    this.bassSpectrum = const [],
    this.bassBinHz = 0,
    this.bandLevels = const [],
    this.bandResolution = AnalyzerBandResolution.third,
    this.meterPeak = const [],
    this.meterRms = const [],
  });
  final List<double> bandLevels, meterPeak, meterRms;
  final AnalyzerBandResolution bandResolution;
  List<double> get displayPeak => meterPeak.isEmpty ? peak : meterPeak;
  List<double> get displayRms => meterRms.isEmpty ? rms : meterRms;
  final int sampleRate;

  /// Explicit spacing permits a transport to omit inaudible FFT bins.
  final double spectrumBinHz;

  /// Already corrected display levels at equally spaced log frequencies.
  final bool logSpectrum;

  /// Linear-bin, Hann coherent-gain corrected amplitude, Max-L/R (no mono or polarity penalty).
  final List<double> spectrum;

  /// Longer Hann FFT for the 250–350 Hz crossover; empty during initial warm-up.
  final List<double> bassSpectrum;
  final double bassBinHz;

  /// Calibrated display frame. DSP and developer tests retain the raw frame.
  AnalyzerFrame calibrated(double offset) {
    if (offset == 0) return this;
    final gain = math.pow(10, offset / 20).toDouble();
    List<double> db(List<double> values) =>
        values.map((v) => v + offset).toList();
    List<double> linear(List<double> values) =>
        values.map((v) => v * gain).toList();
    return AnalyzerFrame(
      sampleRate: sampleRate,
      spectrumBinHz: spectrumBinHz,
      logSpectrum: logSpectrum,
      spectrum: linear(spectrum),
      bassSpectrum: linear(bassSpectrum),
      bassBinHz: bassBinHz,
      peak: db(peak),
      rms: db(rms),
      meterPeak: db(meterPeak),
      meterRms: db(meterRms),
      clipped: peak.map((v) => v + offset >= -0.00027).toList(),
      seconds: seconds,
      bandLevels: db(bandLevels),
      bandResolution: bandResolution,
    );
  }

  AnalyzerFrame withBass(List<double> bass, double spacing) => AnalyzerFrame(
    sampleRate: sampleRate,
    spectrum: spectrum,
    spectrumBinHz: spectrumBinHz,
    logSpectrum: logSpectrum,
    peak: peak,
    rms: rms,
    clipped: clipped,
    seconds: seconds,
    bassSpectrum: bass,
    bassBinHz: spacing,
    bandLevels: bandLevels,
    bandResolution: bandResolution,
    meterPeak: meterPeak,
    meterRms: meterRms,
  );
  final List<double> peak, rms;
  final List<bool> clipped;
  final double seconds;
  double get binHz => spectrumBinHz > 0
      ? spectrumBinHz
      : sampleRate / ((spectrum.length - 1) * 2);

  factory AnalyzerFrame.fromMap(Map<dynamic, dynamic> m) => AnalyzerFrame(
    sampleRate: m['sampleRate'] as int,
    spectrum: (m['spectrum'] as List)
        .cast<num>()
        .map((n) => n.toDouble())
        .toList(),
    peak: (m['peak'] as List).cast<num>().map((n) => n.toDouble()).toList(),
    rms: (m['rms'] as List).cast<num>().map((n) => n.toDouble()).toList(),
    clipped: (m['clipped'] as List).cast<bool>(),
    seconds: (m['seconds'] as num).toDouble(),
    bassSpectrum:
        (m['bassSpectrum'] as List?)
            ?.cast<num>()
            .map((n) => n.toDouble())
            .toList() ??
        const [],
    bassBinHz: (m['bassBinHz'] as num?)?.toDouble() ?? 0,
    bandLevels:
        (m['bandLevels'] as List?)
            ?.cast<num>()
            .map((v) => v.toDouble())
            .toList() ??
        const [],
    bandResolution: AnalyzerBandResolution.values.firstWhere(
      (r) => r.bandsPerOctave == m['bandsPerOctave'],
      orElse: () => AnalyzerBandResolution.third,
    ),
    meterPeak:
        (m['meterPeak'] as List?)
            ?.cast<num>()
            .map((v) => v.toDouble())
            .toList() ??
        const [],
    meterRms:
        (m['meterRms'] as List?)
            ?.cast<num>()
            .map((v) => v.toDouble())
            .toList() ??
        const [],
  );
}

/// Keep transients, clipping and time-weighted RMS when a transport coalesces
/// frames. The most recent spectrum, bands and ballistic meter values win.
AnalyzerFrame coalesceAnalyzerFrames(AnalyzerFrame? old, AnalyzerFrame next) {
  if (old == null ||
      old.sampleRate != next.sampleRate ||
      old.bandResolution != next.bandResolution) {
    return next;
  }
  final seconds = old.seconds + next.seconds;
  return AnalyzerFrame(
    sampleRate: next.sampleRate,
    spectrum: next.spectrum,
    spectrumBinHz: next.spectrumBinHz,
    logSpectrum: next.logSpectrum,
    bassSpectrum: next.bassSpectrum,
    bassBinHz: next.bassBinHz,
    bandLevels: next.bandLevels,
    bandResolution: next.bandResolution,
    peak: List.generate(2, (i) => math.max(old.peak[i], next.peak[i])),
    rms: List.generate(
      2,
      (i) => amplitudeDb(
        math.sqrt(
          (math.pow(10, old.rms[i] / 10) * old.seconds +
                  math.pow(10, next.rms[i] / 10) * next.seconds) /
              seconds,
        ),
      ),
    ),
    meterPeak: next.meterPeak,
    meterRms: next.meterRms,
    clipped: List.generate(2, (i) => old.clipped[i] || next.clipped[i]),
    seconds: seconds,
  );
}

/// Reference implementation and iOS groundwork. Android performs this in its
/// recording worker. Periodic Hann, 75% overlap; independent 60 Hz filter/meter frames.
class AnalyzerDsp {
  AnalyzerDsp({this.size = 2048, this.bassAnalysis = true}) {
    if (size < 4 || size & (size - 1) != 0) {
      throw ArgumentError.value(size, 'size', 'Must be a power of two');
    }
    window = Float64List.fromList(
      List.generate(size, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * i / size)),
    );
  }
  final int size;
  final bool bassAnalysis;
  AnalyzerDsp? _bassDsp, _fastDsp;
  int? _bassRate;
  AnalyzerBandResolution bandResolution = AnalyzerBandResolution.third;
  AnalyzerFilterBank? _bank;
  AnalyzerMeters? _meters;
  List<double> _bass = const [], _fast = const [];
  int _sinceFrame = 0;
  final _peaks = [0.0, 0.0];
  final _squares = [0.0, 0.0];
  final _clipped = [false, false];
  late final Float64List window;
  late final _cosines = Float64List.fromList(
    List.generate(size ~/ 2, (i) => math.cos(-2 * math.pi * i / size)),
  );
  late final _sines = Float64List.fromList(
    List.generate(size ~/ 2, (i) => math.sin(-2 * math.pi * i / size)),
  );
  final List<double> _pending = [];

  List<AnalyzerFrame> add(List<double> stereo, int sampleRate) {
    if (stereo.length.isOdd || sampleRate < 40000) {
      throw ArgumentError('Interleaved stereo at >=40 kHz required');
    }
    if (!bassAnalysis) {
      _pending.addAll(stereo);
      final frames = <AnalyzerFrame>[];
      while (_pending.length >= size * 2) {
        frames.add(analyze(_pending.sublist(0, size * 2), sampleRate));
        _pending.removeRange(0, size ~/ 2); // 75% overlap, stereo
      }
      return frames;
    }
    if (_bassRate != sampleRate) {
      _bassRate = sampleRate;
      _bass = [];
      _fast = [];
      _sinceFrame = 0;
      _bassDsp = AnalyzerDsp(
        size: analyzerBassSize(sampleRate),
        bassAnalysis: false,
      );
      _fastDsp = AnalyzerDsp(
        size: analyzerFastSize(sampleRate),
        bassAnalysis: false,
      );
      _bank = null;
      _meters = AnalyzerMeters(sampleRate);
      for (var ch = 0; ch < 2; ch++) {
        _peaks[ch] = 0;
        _squares[ch] = 0;
        _clipped[ch] = false;
      }
    }
    if (_bank?.resolution != bandResolution) {
      _bank = AnalyzerFilterBank(sampleRate, bandResolution);
    }
    final result = <AnalyzerFrame>[];
    // Segment at display boundaries so an input block never leaks future
    // samples into earlier frames; arbitrary capture block sizes are supported.
    final hop = (sampleRate / 60).round();
    for (var offset = 0; offset < stereo.length;) {
      final count = math.min(hop - _sinceFrame, (stereo.length - offset) ~/ 2);
      final chunk = stereo.sublist(offset, offset + count * 2);
      for (final f in _fastDsp!.add(chunk, sampleRate)) {
        _fast = f.spectrum;
      }
      for (final f in _bassDsp!.add(chunk, sampleRate)) {
        _bass = f.spectrum;
      }
      for (var i = 0; i < chunk.length; i += 2) {
        _bank!.process(chunk[i], chunk[i + 1]);
        _meters!.process(chunk[i], chunk[i + 1]);
        for (var ch = 0; ch < 2; ch++) {
          final v = chunk[i + ch];
          _peaks[ch] = math.max(_peaks[ch], v.abs());
          _squares[ch] += v * v;
          _clipped[ch] |= v.abs() >= 0.999969;
        }
      }
      offset += count * 2;
      _sinceFrame += count;
      if (_sinceFrame == hop) {
        result.add(
          AnalyzerFrame(
            sampleRate: sampleRate,
            spectrum: _fast.isEmpty
                ? List.filled(_fastDsp!.size ~/ 2 + 1, 0)
                : _fast,
            bassSpectrum: _bass,
            bassBinHz: sampleRate / _bassDsp!.size,
            peak: _peaks.map(amplitudeDb).toList(),
            rms: _squares.map((v) => amplitudeDb(math.sqrt(v / hop))).toList(),
            clipped: List.of(_clipped),
            seconds: hop / sampleRate,
            bandLevels: _bank!.levels,
            bandResolution: bandResolution,
            meterPeak: _meters!.peak,
            meterRms: _meters!.rms,
          ),
        );
        _sinceFrame = 0;
        for (var ch = 0; ch < 2; ch++) {
          _peaks[ch] = 0;
          _squares[ch] = 0;
          _clipped[ch] = false;
        }
      }
    }
    return result;
  }

  AnalyzerFrame analyze(List<double> stereo, int sampleRate) {
    if (stereo.length != size * 2) throw ArgumentError('Stereo frame required');
    final power = Float64List(size ~/ 2 + 1);
    final peaks = <double>[0, 0], rms = <double>[0, 0];
    final clipped = <bool>[false, false];
    for (var ch = 0; ch < 2; ch++) {
      final re = Float64List(size), im = Float64List(size);
      double sum = 0;
      for (var i = 0; i < size; i++) {
        final v = stereo[2 * i + ch];
        peaks[ch] = math.max(peaks[ch], v.abs());
        clipped[ch] |= v.abs() >= 0.999969;
        sum += v * v;
        re[i] = v * window[i];
      }
      rms[ch] = amplitudeDb(math.sqrt(sum / size));
      peaks[ch] = amplitudeDb(peaks[ch]);
      _fft(re, im);
      for (var k = 0; k < power.length; k++) {
        final scale = (k == 0 || k == size ~/ 2) ? 2 / size : 4 / size;
        power[k] = math.max(
          power[k],
          (re[k] * re[k] + im[k] * im[k]) * scale * scale,
        );
      }
    }
    return AnalyzerFrame(
      sampleRate: sampleRate,
      spectrum: power.map(math.sqrt).toList(),
      peak: peaks,
      rms: rms,
      clipped: clipped,
      seconds: size / 4 / sampleRate,
    );
  }

  void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (int i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final r = re[i];
        re[i] = re[j];
        re[j] = r;
        final v = im[i];
        im[i] = im[j];
        im[j] = v;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final stride = size ~/ len;
      for (var start = 0; start < n; start += len) {
        for (var j = 0; j < len ~/ 2; j++) {
          final c = _cosines[j * stride], s = _sines[j * stride];
          final a = start + j, b = a + len ~/ 2;
          final r = re[b] * c - im[b] * s;
          final v = re[b] * s + im[b] * c;
          re[b] = re[a] - r;
          im[b] = im[a] - v;
          re[a] += r;
          im[a] += v;
        }
      }
    }
  }
}

/// Time-based display ballistics. Configurable hold, then decay by 12 dB/s.
class AnalyzerEnvelope {
  AnalyzerBallistics ballistics = AnalyzerBallistics.medium;
  double _holdSeconds = 1;
  double get holdSeconds => _holdSeconds;
  set holdSeconds(double value) {
    if (_holdSeconds == value) return;
    _holdSeconds = value;
    // Restart existing markers with the newly selected duration immediately.
    _hold = List.filled(_hold.length, value);
  }

  List<double> values = [], held = [], _hold = [];

  /// Peak-Marken auf den aktuellen Pegel zurücksetzen (z. B. bei ∞ Hold).
  void resetHeld() {
    held = List.of(values);
    _hold = List.filled(values.length, holdSeconds);
  }

  void reset() {
    values = [];
    held = [];
    _hold = [];
  }

  void update(List<double> db, double seconds) {
    if (values.length != db.length) {
      values = List.filled(db.length, analyzerFloor);
      held = List.filled(db.length, analyzerFloor);
      _hold = List.filled(db.length, 0);
    }
    final release = switch (ballistics) {
      AnalyzerBallistics.fast => 60.0,
      AnalyzerBallistics.medium => 25.0,
      AnalyzerBallistics.slow => 10.0,
    };
    for (var i = 0; i < db.length; i++) {
      values[i] = math.max(db[i], values[i] - release * seconds);
      if (db[i] >= held[i]) {
        held[i] = db[i];
        _hold[i] = holdSeconds;
      } else {
        final decayTime = math.max(0.0, seconds - _hold[i]);
        _hold[i] = math.max(0, _hold[i] - seconds);
        held[i] = math.max(db[i], held[i] - 12 * decayTime);
      }
    }
  }
}

/// Integrate the fraction of each bin's frequency cell covered by the band.
/// This conserves power across adjacent bands, including bands narrower than a
/// bin. Hann ENBW = 1.5 bins. Bass uses the longer FFT once it has warmed up.
List<double> octaveBandDb(
  AnalyzerFrame frame,
  AnalyzerBandResolution resolution,
) =>
    frame.bandLevels.length == resolution.count &&
        frame.bandResolution == resolution
    ? frame.bandLevels
    : List.generate(resolution.count, (band) {
        final centre = resolution.centre(band);
        final lo = centre / resolution.edgeRatio;
        final hi = centre * resolution.edgeRatio;
        final bass =
            hi <= analyzerBassLimit(frame.sampleRate) &&
            frame.bassSpectrum.isNotEmpty;
        final bins = bass ? frame.bassSpectrum : frame.spectrum;
        final spacing = bass ? frame.bassBinHz : frame.binHz;
        double power = 0;
        final first = math.max(0, (lo / spacing - 0.5).ceil());
        final last = math.min(bins.length - 1, (hi / spacing + 0.5).floor());
        for (var k = first; k <= last; k++) {
          final overlap = math.max(
            0.0,
            math.min(
                  hi,
                  (k == bins.length - 1 && !bass ? k : k + 0.5) * spacing,
                ) -
                math.max(lo, (k - 0.5) * spacing),
          );
          // DC/Nyquist have half-sized one-sided cells and half amplitude.
          final endpoint = k == 0 || k == bins.length - 1 && !bass;
          power += bins[k] * bins[k] * overlap / spacing * (endpoint ? 4 : 1);
        }
        return amplitudeDb(math.sqrt(power / 1.5));
      });

List<double> thirdOctaveDb(AnalyzerFrame frame) =>
    octaveBandDb(frame, AnalyzerBandResolution.third);

/// One value per log-axis pixel, including both endpoints. Interpolate between
/// bin levels in the sparse bass region; preserve bin maxima in dense columns.
List<double> logSpectrumDb(List<double> db, double binHz, int columns) {
  if (db.isEmpty || columns < 2) return const [];
  return List.generate(columns, (column) {
    final position = (frequencyAt(column / (columns - 1)) / binHz).clamp(
      0.0,
      db.length - 1.0,
    );
    final left = position.floor(), right = math.min(left + 1, db.length - 1);
    var value = db[left] + (db[right] - db[left]) * (position - left);
    final lo = frequencyAt((column - 0.5) / (columns - 1)) / binHz;
    final hi = frequencyAt((column + 0.5) / (columns - 1)) / binHz;
    if (hi - lo >= 1) {
      for (
        var k = math.max(1, lo.ceil());
        k <= math.min(db.length - 1, hi.floor());
        k++
      ) {
        value = math.max(value, db[k]);
      }
    }
    return value;
  });
}

/// Three-bin log-parabola removes Hann scalloping at isolated spectral peaks
/// (raw coherent-gain bins stay unchanged for ENBW power integration).
List<double> analyzerLineDb(List<double> bins) {
  final db = bins.map(amplitudeDb).toList();
  final result = List<double>.of(db);
  for (var i = 1; i < db.length - 1; i++) {
    if (db[i] > db[i - 1] && db[i] >= db[i + 1] && db[i] > -100) {
      final curvature = db[i - 1] - 2 * db[i] + db[i + 1];
      if (curvature < -0.01) {
        final offset = (0.5 * (db[i - 1] - db[i + 1]) / curvature).clamp(
          -0.5,
          0.5,
        );
        result[i] = db[i] - 0.25 * (db[i - 1] - db[i + 1]) * offset;
      }
    }
  }
  return result;
}

/// Resample an already logarithmic display, retaining maxima when reducing it.
List<double> resampleLogSpectrum(List<double> values, int columns) {
  if (values.length < 2 || columns < 2) return const [];
  return List.generate(columns, (i) {
    final x = i * (values.length - 1) / (columns - 1);
    final lo = x.floor(), hi = math.min(lo + 1, values.length - 1);
    var value = values[lo] + (values[hi] - values[lo]) * (x - lo);
    for (
      var k = math.max(
        0,
        ((i - .5) * (values.length - 1) / (columns - 1)).ceil(),
      );
      k <=
          math.min(
            values.length - 1,
            ((i + .5) * (values.length - 1) / (columns - 1)).floor(),
          );
      k++
    ) {
      value = math.max(value, values[k]);
    }
    return value;
  });
}
