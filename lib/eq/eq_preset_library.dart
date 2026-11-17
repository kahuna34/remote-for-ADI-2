import 'dart:convert';

import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'eq_library.dart';
import 'eq_model.dart';

class EqLibraryNote {
  const EqLibraryNote(this.kind, this.band, this.param, this.from, this.to);
  final String kind, band, param;
  final num from, to;
}

class EqLibraryDeviation {
  const EqLibraryDeviation({required this.reference, required this.original10});
  final String reference;
  final double original10;
}

class EqLibraryGenerated {
  const EqLibraryGenerated({required this.basis, required this.deviation});
  final String basis;
  final double deviation;
}

class EqLibraryFit {
  EqLibraryFit({required Map<int, int> left, this.basis = '', this.deviation})
    : left = Map.unmodifiable(left);
  final Map<int, int> left;
  final String basis;
  final double? deviation;
}

class EqLibraryMeasured {
  const EqLibraryMeasured({
    required this.original10,
    required this.preset,
    required this.fit,
  });
  final double original10, preset, fit;
}

class EqLibraryEntry {
  EqLibraryEntry({
    required this.brand,
    required this.model,
    required this.variant,
    required this.target,
    required this.name,
    required Map<int, int> left,
    required this.notes,
    this.fit,
    this.generated,
    this.deviation,
    this.measured,
  }) : left = Map.unmodifiable(left);
  final String brand, model, variant, target, name;
  final Map<int, int> left;
  final List<EqLibraryNote> notes;
  final EqLibraryFit? fit;
  final EqLibraryGenerated? generated;
  final EqLibraryDeviation? deviation;
  final EqLibraryMeasured? measured;

  bool matches(String query) => '$brand $model $variant'.toLowerCase().contains(
    query.trim().toLowerCase(),
  );

  AppEqPreset toAppPreset({bool personal = false, bool fitted = false}) {
    final suffix = generated != null || fitted && fit != null
        ? tr(' (angepasst)')
        : '';
    return AppEqPreset(
      name: '${personal ? '$name – $target' : name}$suffix',
      dual: false,
      left: Map.of(fitted ? fit?.left ?? left : left),
      right: {},
    );
  }
}

abstract final class EqPresetLibrary {
  static Future<List<EqLibraryEntry>>? _cached;
  static Future<List<EqLibraryEntry>> load() => _cached ??= rootBundle
      .loadString('assets/eq_library/oratory1990.json')
      .then(parse);

  static List<EqLibraryEntry> parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map ||
        json['type'] != 'adi2-eq-library' ||
        ![1, 2, 3].contains(json['version']) ||
        json['presets'] is! List) {
      throw const FormatException('Invalid EQ library');
    }
    final entries = <EqLibraryEntry>[];
    for (final item in json['presets']) {
      if (item is! Map) continue;
      String field(String key) =>
          item[key] is String ? (item[key] as String).trim() : '';
      if ([
            'brand',
            'model',
            'target',
            'name',
          ].any((key) => field(key).isEmpty) ||
          item['l'] is! Map) {
        continue;
      }
      final left = _readValues(item['l']);
      if (left == null) continue;
      final rawGenerated = item['generated'];
      final generatedDeviation = rawGenerated is Map
          ? _distance(rawGenerated['deviation'])
          : null;
      final generatedBasis = rawGenerated is Map
          ? _text(rawGenerated['basis'])
          : '';
      final rawFit = item['fit'];
      final fitLeft = rawFit is Map ? _readValues(rawFit['l']) : null;
      final rawDeviation = item['deviation'];
      final original10 = rawDeviation is Map
          ? _distance(rawDeviation['original10'])
          : null;
      final rawMeasured = item['measured'];
      final measuredOriginal = rawMeasured is Map
          ? _distance(rawMeasured['original10'])
          : null;
      final measuredPreset = rawMeasured is Map
          ? _distance(rawMeasured['preset'])
          : null;
      final measuredFit = rawMeasured is Map
          ? _distance(rawMeasured['fit'])
          : null;
      final notes = <EqLibraryNote>[];
      if (item['notes'] is List) {
        for (final note in item['notes']) {
          if (note is! Map || note['band'] is! String) continue;
          if (note['kind'] == 'clamped' &&
              ['q', 'freq'].contains(note['param']) &&
              note['from'] is num &&
              note['to'] is num &&
              (note['from'] as num).isFinite &&
              (note['to'] as num).isFinite) {
            notes.add(
              EqLibraryNote(
                'clamped',
                note['band'],
                note['param'],
                note['from'],
                note['to'],
              ),
            );
          } else if (note['kind'] == 'dropped' &&
              note['filter'] == 'highShelf' &&
              note['freq'] is num &&
              (note['freq'] as num).isFinite) {
            notes.add(
              EqLibraryNote('dropped', note['band'], 'freq', note['freq'], 0),
            );
          }
        }
      }
      entries.add(
        EqLibraryEntry(
          brand: field('brand'),
          model: field('model'),
          variant: field('variant'),
          target: field('target'),
          name: field('name'),
          left: left,
          notes: List.unmodifiable(notes),
          generated: generatedDeviation == null || generatedBasis.isEmpty
              ? null
              : EqLibraryGenerated(
                  basis: generatedBasis,
                  deviation: generatedDeviation,
                ),
          fit: fitLeft == null
              ? null
              : EqLibraryFit(
                  left: fitLeft,
                  basis: _text(rawFit['basis']),
                  deviation: _distance(rawFit['deviation']),
                ),
          deviation: original10 == null
              ? null
              : EqLibraryDeviation(
                  reference: _text(rawDeviation['reference']),
                  original10: original10,
                ),
          measured:
              measuredOriginal == null ||
                  measuredPreset == null ||
                  measuredFit == null
              ? null
              : EqLibraryMeasured(
                  original10: measuredOriginal,
                  preset: measuredPreset,
                  fit: measuredFit,
                ),
        ),
      );
    }
    entries.sort(
      (a, b) => '${a.brand} ${a.model} ${a.variant}'.toLowerCase().compareTo(
        '${b.brand} ${b.model} ${b.variant}'.toLowerCase(),
      ),
    );
    return List.unmodifiable(entries);
  }

  static String _text(Object? value) => value is String ? value.trim() : '';

  static double? _distance(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

  // All versions pass through the same required-field checks and limits.
  static Map<int, int>? _readValues(Object? raw) {
    if (raw is! Map) return null;
    final values = <int, int>{20: 1};
    for (final band in eqBands) {
      for (final index in [
        band.gainIdx,
        band.freqIdx,
        band.qIdx,
        ?band.typeIdx,
      ]) {
        final value = raw['$index'];
        if (value is! int) return null;
        values[index] = index == band.gainIdx
            ? value.clamp(eqGainMinRaw, eqGainMaxRaw)
            : index == band.freqIdx
            ? value.clamp(band.minF, band.maxF)
            : index == band.qIdx
            ? value.clamp((band.minQ * 10).round(), (band.maxQ * 10).round())
            : value.clamp(0, 1);
      }
    }
    return values;
  }

  static Future<bool> addToPersonal(
    EqLibraryEntry entry, {
    bool fitted = false,
  }) async {
    final preset = entry.toAppPreset(personal: true, fitted: fitted);
    final base = '${entry.name} – ${entry.target}';
    // Recognize an adjusted copy even after the app language changes.
    final names = entry.generated != null || fitted && entry.fit != null
        ? {'$base (angepasst)', '$base (adjusted)'}
        : {base};
    final items = await EqLibrary.load();
    if (items.any((p) => names.contains(p.name))) return false;
    await EqLibrary.save([...items, preset]);
    return true;
  }
}
