import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analyzer/analyzer_dsp.dart';

const hostAnalyzerInterval = Duration(milliseconds: 20); // At most 50 fps.
const hostAnalyzerLegacyInterval = Duration(milliseconds: 160);
const hostAnalyzerVersion = 2;
const hostAnalyzerColumns = 256;

int negotiateHostAnalyzerVersion(Object? advertised) =>
    advertised is int && advertised >= 1
    ? math.min(advertised, hostAnalyzerVersion)
    : 0;

AnalyzerBandResolution hostAnalyzerResolution(Object? value) =>
    AnalyzerBandResolution.values.firstWhere(
      (r) => r.bandsPerOctave == value,
      orElse: () => throw const FormatException('Analyzer band resolution'),
    );

/// Little-endian signed Int16, tenths of a dB. FFT amplitudes are converted
/// back to linear on receipt so the existing interpolation/calibration applies.
String _pack(List<double> values, {bool linear = false}) {
  final bytes = ByteData(values.length * 2);
  for (var i = 0; i < values.length; i++) {
    final db = linear ? amplitudeDb(values[i]) : values[i];
    bytes.setInt16(i * 2, (db.clamp(-120, 120) * 10).round(), Endian.little);
  }
  return base64Encode(bytes.buffer.asUint8List());
}

List<double> _unpack(Object? value, {bool linear = false, int max = 1100}) {
  if (value is! String || value.length > max * 3) {
    throw const FormatException('Analyzer levels');
  }
  final bytes = base64Decode(value);
  if (bytes.length.isOdd || bytes.length > max * 2) {
    throw const FormatException('Analyzer levels size');
  }
  final data = ByteData.sublistView(bytes);
  return List.generate(bytes.length ~/ 2, (i) {
    final db = data.getInt16(i * 2, Endian.little) / 10;
    if (db < -120 || db > 120) throw const FormatException('Analyzer dB');
    return linear ? math.pow(10, db / 20).toDouble() : db;
  });
}

List<double> _through(List<double> bins, double spacing, double hz) =>
    bins.take(math.min(bins.length, (hz / spacing).ceil() + 1)).toList();

Map<String, dynamic> encodeHostAnalyzerFrame(AnalyzerFrame f) => {
  'v': 1,
  'sampleRate': f.sampleRate,
  'seconds': f.seconds,
  'binHz': f.binHz,
  'bassBinHz': f.bassBinHz,
  'bandResolution': f.bandResolution.bandsPerOctave,
  'spectrum': _pack(_through(f.spectrum, f.binHz, 20000), linear: true),
  'bass': _pack(
    f.bassSpectrum.isEmpty ? [] : _through(f.bassSpectrum, f.bassBinHz, 400),
    linear: true,
  ),
  'bands': _pack(f.bandLevels),
  'meters': _pack([...f.peak, ...f.rms, ...f.displayPeak, ...f.displayRms]),
  'clip': (f.clipped[0] ? 1 : 0) | (f.clipped[1] ? 2 : 0),
};

AnalyzerFrame decodeHostAnalyzerFrame(Map<dynamic, dynamic> m) {
  if (m['v'] == 2) return _decodeV2(m);
  double number(String key, double min, double max) {
    final value = m[key];
    if (value is! num || !value.isFinite || value < min || value > max) {
      throw FormatException('Analyzer $key');
    }
    return value.toDouble();
  }

  if (m['v'] != 1) throw const FormatException('Analyzer frame version');
  final rate = number('sampleRate', 40000, 1536000).toInt();
  final seconds = number('seconds', 0.001, 2);
  final spacing = number('binHz', 1, 100);
  final bassSpacing = number('bassBinHz', 0, 100);
  final resolution = hostAnalyzerResolution(m['bandResolution']);
  final spectrum = _unpack(m['spectrum'], linear: true);
  final bass = _unpack(m['bass'], linear: true, max: 128);
  final bands = _unpack(m['bands'], max: 128);
  final meters = _unpack(m['meters'], max: 8);
  final clip = m['clip'];
  if (spectrum.length < 2 ||
      bands.length != resolution.count ||
      meters.length != 8 ||
      (bass.isNotEmpty && bassSpacing <= 0) ||
      clip is! int ||
      clip < 0 ||
      clip > 3) {
    throw const FormatException('Analyzer frame shape');
  }
  return AnalyzerFrame(
    sampleRate: rate,
    spectrumBinHz: spacing,
    spectrum: spectrum,
    bassSpectrum: bass,
    bassBinHz: bassSpacing,
    bandLevels: bands,
    bandResolution: resolution,
    peak: meters.sublist(0, 2),
    rms: meters.sublist(2, 4),
    meterPeak: meters.sublist(4, 6),
    meterRms: meters.sublist(6, 8),
    clipped: [clip & 1 != 0, clip & 2 != 0],
    seconds: seconds,
  );
}

// 0 is the -120 dB floor; 1..255 represents -115..+12 dB in half-dB steps.
String _pack8(List<double> db) => base64Encode(
  db
      .map((v) => v < -115 ? 0 : 1 + ((v.clamp(-115, 12) + 115) * 2).round())
      .toList(),
);
List<double> _unpack8(Object? value, int max) {
  if (value is! String || value.length > ((max + 2) ~/ 3) * 4) {
    throw const FormatException('Analyzer byte levels');
  }
  final bytes = base64Decode(value);
  if (bytes.length > max) throw const FormatException('Analyzer byte size');
  return bytes.map((v) => v == 0 ? -120.0 : (v - 1) / 2 - 115).toList();
}

/// Bass is folded into the display curve; bars need only the filter-bank levels.
Map<String, dynamic> encodeHostAnalyzerFrameV2(
  AnalyzerFrame f, {
  bool bars = false,
}) {
  var line = <double>[];
  if (!bars) {
    line = logSpectrumDb(
      analyzerLineDb(f.spectrum),
      f.binHz,
      hostAnalyzerColumns,
    );
    if (f.bassSpectrum.isNotEmpty && f.bassBinHz > 0) {
      final bass = logSpectrumDb(
        analyzerLineDb(f.bassSpectrum),
        f.bassBinHz,
        hostAnalyzerColumns,
      );
      for (var i = 0; i < line.length; i++) {
        final blend = ((frequencyAt(i / (line.length - 1)) - 250) / 100).clamp(
          0.0,
          1.0,
        );
        line[i] = bass[i] * (1 - blend) + line[i] * blend;
      }
    }
  }
  return {
    'v': 2,
    'ms': (f.seconds * 1000).round().clamp(1, 2000),
    'r': f.bandResolution.bandsPerOctave,
    if (!bars) 's': _pack8(line),
    if (bars) 'b': _pack8(f.bandLevels),
    'm': _pack8([...f.peak, ...f.rms, ...f.displayPeak, ...f.displayRms]),
    'c': (f.clipped[0] ? 1 : 0) | (f.clipped[1] ? 2 : 0),
  };
}

AnalyzerFrame _decodeV2(Map<dynamic, dynamic> m) {
  final rate = m['sampleRate'], ms = m['ms'], clip = m['c'];
  final resolution = hostAnalyzerResolution(m['r']);
  final line = m.containsKey('s')
      ? _unpack8(m['s'], hostAnalyzerColumns)
      : <double>[];
  final bands = m.containsKey('b') ? _unpack8(m['b'], 128) : <double>[];
  final meters = _unpack8(m['m'], 8);
  if (rate is! int ||
      rate < 40000 ||
      rate > 1536000 ||
      ms is! int ||
      ms < 1 ||
      ms > 2000 ||
      clip is! int ||
      clip < 0 ||
      clip > 3 ||
      meters.length != 8 ||
      !(line.length == hostAnalyzerColumns && bands.isEmpty ||
          line.isEmpty && bands.length == resolution.count)) {
    throw const FormatException('Analyzer v2 shape');
  }
  return AnalyzerFrame(
    sampleRate: rate,
    seconds: ms / 1000,
    logSpectrum: true,
    spectrum: line.map((v) => math.pow(10, v / 20).toDouble()).toList(),
    bandResolution: resolution,
    bandLevels: bands,
    peak: meters.sublist(0, 2),
    rms: meters.sublist(2, 4),
    meterPeak: meters.sublist(4, 6),
    meterRms: meters.sublist(6, 8),
    clipped: [clip & 1 != 0, clip & 2 != 0],
  );
}
