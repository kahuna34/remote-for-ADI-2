// EQ-Bänder laut RME MIDI-Protokoll v1.2 (Adressen 1/4/7/10 links,
// 2/5/8/11 rechts). Rohwerte: Gain = dB × 2, Q = Q × 10, Frequenz in Hz.

import 'dart:math' as math;

import 'eq_math.dart';

class EqBandDef {
  const EqBandDef({
    required this.label,
    required this.gainIdx,
    required this.freqIdx,
    required this.qIdx,
    this.typeIdx,
    this.types = const [],
    required this.minF,
    required this.maxF,
    required this.minQ,
    required this.maxQ,
    required this.defF,
    required this.defQ,
    this.fixedKind,
    this.freqStep100 = false,
  });

  final String label;
  final int gainIdx, freqIdx, qIdx;
  final int? typeIdx;
  final List<(String, FilterKind)> types;
  final int minF, maxF;
  final double minQ, maxQ;
  final int defF;
  final double defQ;
  final FilterKind? fixedKind;
  final bool freqStep100;

  bool get isBassTreble => fixedKind != null;

  FilterKind kindFor(int? typeRaw) {
    if (fixedKind != null) return fixedKind!;
    final i = (typeRaw ?? 0).clamp(0, types.length - 1);
    return types[i].$2;
  }

  String typeName(int? typeRaw) {
    if (fixedKind != null) return 'Shelf';
    final i = (typeRaw ?? 0).clamp(0, types.length - 1);
    return types[i].$1;
  }
}

const eqBands = <EqBandDef>[
  EqBandDef(
    label: '1',
    typeIdx: 3,
    gainIdx: 4,
    freqIdx: 5,
    qIdx: 6,
    types: [
      ('Peak', FilterKind.peak),
      ('Shelf', FilterKind.lowShelf),
      ('Hochpass', FilterKind.highPass),
      ('Tiefpass', FilterKind.lowPass),
    ],
    minF: 20,
    maxF: 20000,
    minQ: 0.5,
    maxQ: 9.9,
    defF: 100,
    defQ: 1.0,
  ),
  EqBandDef(
    label: '2',
    gainIdx: 7,
    freqIdx: 8,
    qIdx: 9,
    types: [('Peak', FilterKind.peak)],
    minF: 20,
    maxF: 20000,
    minQ: 0.5,
    maxQ: 9.9,
    defF: 500,
    defQ: 1.0,
  ),
  EqBandDef(
    label: '3',
    gainIdx: 10,
    freqIdx: 11,
    qIdx: 12,
    types: [('Peak', FilterKind.peak)],
    minF: 20,
    maxF: 20000,
    minQ: 0.5,
    maxQ: 9.9,
    defF: 1000,
    defQ: 1.0,
  ),
  EqBandDef(
    label: '4',
    gainIdx: 13,
    freqIdx: 14,
    qIdx: 15,
    types: [('Peak', FilterKind.peak)],
    minF: 200,
    maxF: 20000,
    minQ: 0.5,
    maxQ: 5.0,
    defF: 5000,
    defQ: 1.0,
  ),
  EqBandDef(
    label: '5',
    typeIdx: 16,
    gainIdx: 17,
    freqIdx: 18,
    qIdx: 19,
    types: [
      ('Peak', FilterKind.peak),
      ('Shelf', FilterKind.highShelf),
      ('Tiefpass', FilterKind.lowPass),
    ],
    minF: 200,
    maxF: 20000,
    minQ: 0.5,
    maxQ: 5.0,
    defF: 10000,
    defQ: 1.0,
  ),
  EqBandDef(
    label: 'Bass',
    gainIdx: 21,
    freqIdx: 22,
    qIdx: 23,
    fixedKind: FilterKind.lowShelf,
    minF: 20,
    maxF: 150,
    minQ: 0.5,
    maxQ: 1.5,
    defF: 85,
    defQ: 0.9,
  ),
  EqBandDef(
    label: 'Treble',
    gainIdx: 24,
    freqIdx: 25,
    qIdx: 26,
    fixedKind: FilterKind.highShelf,
    minF: 3000,
    maxF: 10000,
    minQ: 0.5,
    maxQ: 1.5,
    defF: 6500,
    defQ: 0.7,
    freqStep100: true,
  ),
];

abstract final class EqIdx2 {
  /// Preset-Kennung beim Lesen (Gerät -> App), siehe presetFlagReadIdx.
  static const presetFlags = 1;
  static const enable = 2;
  static const btEnable = 20;
  static const loadBtWithPreset = 27;
  static const presetSelect = 28;
}

const int eqGainMinRaw = -24; // −12 dB
const int eqGainMaxRaw = 24; // +12 dB

/// Nächster Frequenzschritt (≈ 1/12 Oktave, gerundet wie am Gerät).
int stepFreq(EqBandDef b, int f, int dir) {
  if (b.freqStep100) return (f + dir * 100).clamp(b.minF, b.maxF);
  final next = f * math.pow(2, dir / 12);
  var r = next.round();
  if (r > 2047) r = (r / 10).round() * 10; // Gerät: ab 2048 Hz 10-Hz-Raster
  if (r == f) r += dir;
  return r.clamp(b.minF, b.maxF);
}

/// Frequenz auf das Geräteraster runden.
int snapFreq(EqBandDef b, double f) {
  var r = f.round();
  if (b.freqStep100) r = (r / 100).round() * 100;
  if (r > 2047) r = (r / 10).round() * 10;
  return r.clamp(b.minF, b.maxF);
}

String fmtFreq(int f) {
  if (f >= 1000) {
    final k = f / 1000;
    return '${k.toStringAsFixed(f % 1000 == 0 ? 0 : (f % 100 == 0 ? 1 : 2)).replaceAll('.', ',')} kHz';
  }
  return '$f Hz';
}

String fmtGain(int raw) {
  final v = raw / 2;
  return '${v < 0 ? '−' : (v > 0 ? '+' : '')}${v.abs().toStringAsFixed(1).replaceAll('.', ',')} dB';
}

String fmtQ(int raw) => (raw / 10).toStringAsFixed(1).replaceAll('.', ',');
