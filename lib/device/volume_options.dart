// Einstellungen zum Lautstärke-Schutz, die die App selbst verwaltet
// (nicht im Gerät): Obergrenze in dBu, Anstiegsgeschwindigkeit,
// Merk-Lautstärke und gekoppelte Ausgänge. Gespeichert je Gerätemodell.

import 'dart:convert';

import '../protocol/adi2_codec.dart';
import '../protocol/adi2_params.dart';
import 'volume_guard.dart';

enum RiseMode {
  adaptive('Adaptiv'),
  db20('20'),
  db10('10'),
  db5('5 dB/s');

  const RiseMode(this.label);
  final String label;

  double Function(double db) get rate => switch (this) {
    RiseMode.adaptive => riseRateDbPerSec,
    RiseMode.db20 => (_) => 20,
    RiseMode.db10 => (_) => 10,
    RiseMode.db5 => (_) => 5,
  };
}

/// Grenzen der dBu-Obergrenze (wie im Original: −60 … +35 dBu).
const double limitDbuMin = -60;
const double limitDbuMax = 35;

/// Ausgangspegel in dBu bei 0 dBFS für den eingestellten Ref-Level.
/// Quelle: Optionstexte im RME-Protokoll, Phones-Werte laut ADI-2-Remote-
/// Handbuch (IEM +1, Lo-Power +7, Hi-Power +19 dBu).
/// Gibt null zurück, wenn der Wert unbekannt ist.
double? refDbu(Adi2Variant v, int address, int? refIndex) {
  final table = refTable(v, address);
  if (table.length == 1) return table.first; // fester Pegel (DAC-IEM)
  if (refIndex == null || refIndex < 0 || refIndex >= table.length) return null;
  return table[refIndex];
}

List<double> refTable(Adi2Variant v, int address) {
  // ADI-2 DAC: IEM-Ausgang (Adresse 9) ohne Ref-Level, fest −3 dBu
  // (ADI-2 Remote Handbuch, Kap. 8.3).
  if (v.isDac && address == Adi2Addr.ph34) return const [-3];
  final phones = address == Adi2Addr.ph12 || address == Adi2Addr.ph34;
  if (phones) return v.isPro4 ? const [1, 7, 19] : const [7, 19];
  return switch (v) {
    Adi2Variant.dac => const [-5, 1, 7, 13],
    Adi2Variant.pro => const [4, 13, 19, 24],
    _ => const [1, 7, 13, 19, 24],
  };
}

/// Höchste erlaubte Lautstärke (Rohwert, 0,1 dB) für eine dBu-Grenze.
/// Ist der Ref-Level unbekannt, wird der höchste mögliche angenommen
/// (sicherste Annahme).
int maxVolumeRaw(double? limitDbu, double? ref, List<double> table) {
  if (limitDbu == null) return volMaxRaw;
  final r = ref ?? table.reduce((a, b) => a > b ? a : b);
  final raw = ((limitDbu - r) * 10).floor();
  // auf 0,5-dB-Schritte abrunden (Geräteraster)
  final stepped = (raw / 5).floor() * 5;
  return stepped.clamp(volMinRaw, volMaxRaw);
}

class OutputOptions {
  OutputOptions({this.limitDbu, this.recallRaw});
  double? limitDbu; // null = keine Grenze
  int? recallRaw; // Merk-Lautstärke, null = nicht gesetzt

  Map<String, dynamic> toJson() => {'l': limitDbu, 'r': recallRaw};
  factory OutputOptions.fromJson(Map<String, dynamic> j) => OutputOptions(
    limitDbu: (j['l'] as num?)?.toDouble(),
    recallRaw: j['r'] as int?,
  );
}

class VolumeOptions {
  VolumeOptions();

  RiseMode rise = RiseMode.adaptive;
  final Map<int, OutputOptions> outputs = {};
  final Set<int> linked = {};

  OutputOptions of(int address) =>
      outputs.putIfAbsent(address, OutputOptions.new);

  String encode() => jsonEncode({
    'rise': rise.name,
    'linked': linked.toList(),
    'out': {for (final e in outputs.entries) '${e.key}': e.value.toJson()},
  });

  static VolumeOptions decode(String? s) {
    final o = VolumeOptions();
    if (s == null) return o;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      o.rise = RiseMode.values.firstWhere(
        (r) => r.name == j['rise'],
        orElse: () => RiseMode.adaptive,
      );
      o.linked.addAll((j['linked'] as List? ?? []).cast<int>());
      final out = j['out'] as Map<String, dynamic>? ?? {};
      for (final e in out.entries) {
        o.outputs[int.parse(e.key)] = OutputOptions.fromJson(
          e.value as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // beschädigte Daten: sichere Standardwerte
    }
    return o;
  }
}
