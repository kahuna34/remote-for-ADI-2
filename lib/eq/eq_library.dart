// EQ-Presets in der App (unabhängig von den 20 Speicherplätzen im Gerät).
// Gespeichert als JSON-Datei im App-Speicher; einzeln als Datei teil- und
// importierbar.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ein EQ-Preset: Rohwerte der EQ-Adresse links (Index 3..26, inkl.
/// Bass/Treble) und rechts (Index 3..19), dazu Dual EQ.
class AppEqPreset {
  AppEqPreset({
    required this.name,
    required this.dual,
    required this.left,
    required this.right,
  });

  final String name;
  final bool dual;
  final Map<int, int> left;
  final Map<int, int> right;

  static const fileType = 'adi2-eq-preset';

  Map<String, dynamic> toJson() => {
    'type': fileType,
    'version': 1,
    'name': name,
    'dual': dual,
    'l': {for (final e in left.entries) '${e.key}': e.value},
    'r': {for (final e in right.entries) '${e.key}': e.value},
  };

  static Map<int, int> _map(Object? o) {
    if (o is! Map) return {};
    final m = <int, int>{};
    for (final e in o.entries) {
      final k = int.tryParse('${e.key}');
      final v = e.value;
      if (k != null && k >= 3 && k <= 26 && v is int) m[k] = v;
    }
    return m;
  }

  factory AppEqPreset.fromJson(Map<String, dynamic> j) {
    if (j['type'] != fileType) {
      throw const FormatException('Keine EQ-Preset-Datei.');
    }
    final left = _map(j['l']);
    if (left.isEmpty) throw const FormatException('Keine EQ-Preset-Datei.');
    return AppEqPreset(
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? (j['name'] as String).trim()
          : 'EQ',
      dual: j['dual'] == true,
      left: left,
      right: _map(j['r'])..removeWhere((k, _) => k > 19),
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static AppEqPreset decode(String s) {
    final j = jsonDecode(s);
    if (j is! Map<String, dynamic>) {
      throw const FormatException('Keine EQ-Preset-Datei.');
    }
    return AppEqPreset.fromJson(j);
  }
}

/// Liste der App-Presets (eine Datei).
class EqLibrary {
  static Future<File> _file() async {
    final base = await getApplicationDocumentsDirectory();
    return File('${base.path}/eq_presets.json');
  }

  static List<AppEqPreset> decodeList(String s) {
    final j = jsonDecode(s);
    if (j is! List) return [];
    final out = <AppEqPreset>[];
    for (final e in j) {
      try {
        if (e is Map<String, dynamic>) out.add(AppEqPreset.fromJson(e));
      } on FormatException {
        // fehlerhaften Eintrag überspringen
      }
    }
    return out;
  }

  static String encodeList(List<AppEqPreset> l) =>
      jsonEncode([for (final p in l) p.toJson()]);

  static Future<List<AppEqPreset>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      return decodeList(await f.readAsString());
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<AppEqPreset> l) async {
    final f = await _file();
    await f.writeAsString(encodeList(l));
  }

  /// Datei zum Teilen eines einzelnen Presets.
  static Future<File> exportFile(AppEqPreset p) async {
    final base = await getTemporaryDirectory();
    final safe = p.name.replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '_').trim();
    final f = File('${base.path}/${safe.isEmpty ? 'EQ' : safe}.adi2eq.json');
    await f.writeAsString(p.encode());
    return f;
  }
}
