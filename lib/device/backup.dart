// Backup-Format: kompletter Gerätezustand + 20 EQ-Presets als JSON-Datei.

import 'dart:convert';

import '../l10n/l10n.dart';

const String backupFormat = 'adi2-fernbedienung-backup';
const int backupVersion = 1;

class EqPresetData {
  EqPresetData({
    required this.number,
    required this.name,
    required this.empty,
    required this.dual,
    Map<int, int>? left,
    Map<int, int>? right,
  }) : left = left ?? {},
       right = right ?? {};

  final int number; // 0..19
  final String name;
  final bool empty;
  final bool dual;
  final Map<int, int> left; // Index -> Rohwert (Adresse 13)
  final Map<int, int> right; // Index -> Rohwert (Adresse 14)

  Map<String, dynamic> toJson() => {
    'n': number,
    'name': name,
    'empty': empty,
    'dual': dual,
    'l': {for (final e in left.entries) '${e.key}': e.value},
    'r': {for (final e in right.entries) '${e.key}': e.value},
  };

  factory EqPresetData.fromJson(Map<String, dynamic> j) => EqPresetData(
    number: j['n'] as int,
    name: j['name'] as String? ?? '',
    empty: j['empty'] as bool? ?? false,
    dual: j['dual'] as bool? ?? false,
    left: _intMap(j['l']),
    right: _intMap(j['r']),
  );
}

Map<int, int> _intMap(dynamic m) => {
  for (final e in (m as Map? ?? {}).entries)
    int.parse(e.key as String): e.value as int,
};

class Adi2Backup {
  Adi2Backup({
    required this.variant,
    required this.label,
    required this.created,
    required this.values,
    required this.presets,
    required this.setupNames,
  });

  final String variant; // Adi2Variant.name
  final String label; // Anzeigename (z. B. "ADI-2 Pro")
  final DateTime created;
  final Map<int, int> values; // address<<8|index -> Rohwert
  final List<EqPresetData> presets;
  final Map<int, String> setupNames; // 1..9

  String encode() => const JsonEncoder.withIndent(' ').convert({
    'format': backupFormat,
    'version': backupVersion,
    'variant': variant,
    'label': label,
    'created': created.toIso8601String(),
    'values': {for (final e in values.entries) '${e.key}': e.value},
    'presets': [for (final p in presets) p.toJson()],
    'setups': {for (final e in setupNames.entries) '${e.key}': e.value},
  });

  /// Liest ein Backup; wirft [FormatException] bei fremden/kaputten Dateien.
  static Adi2Backup decode(String s) {
    final j = jsonDecode(s);
    if (j is! Map || j['format'] != backupFormat) {
      throw FormatException(tr('Keine Backup-Datei dieser App.'));
    }
    if ((j['version'] as int? ?? 0) > backupVersion) {
      throw FormatException(tr('Backup stammt aus einer neueren App-Version.'));
    }
    return Adi2Backup(
      variant: j['variant'] as String,
      label: j['label'] as String? ?? '',
      created:
          DateTime.tryParse(j['created'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      values: _intMap(j['values']),
      presets: [
        for (final p in (j['presets'] as List? ?? []))
          EqPresetData.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
      setupNames: {
        for (final e in (j['setups'] as Map? ?? {}).entries)
          int.parse(e.key as String): e.value as String,
      },
    );
  }

  /// Dateiname, z. B. "ADI-2_Pro_2026-11-05_1612.json".
  String get fileName {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = created;
    return '${label.replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '_')}_'
        '${d.year}-${two(d.month)}-${two(d.day)}_${two(d.hour)}${two(d.minute)}.json';
  }
}
