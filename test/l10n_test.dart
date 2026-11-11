// Prüft die Übersetzungen: alle tr()/trf()-Texte haben eine englische
// Fassung, keine deutschen UI-Texte außerhalb von tr(), alle Geräteparameter
// übersetzt.

import 'dart:io';

import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/l10n/strings_en.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter_test/flutter_test.dart';

/// Liest Dart-Literal(e) wie 'a' 'b' (aneinandergereiht) als einen Text.
String _joinLiterals(String src) {
  final parts = RegExp(r"'((?:[^'\\]|\\.)*)'").allMatches(src);
  return parts
      .map((m) => m.group(1)!.replaceAll(r"\'", "'").replaceAll(r'\n', '\n'))
      .join();
}

Iterable<File> _dartFiles() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        // Unter Windows liefert listSync Backslashes; Pfade vereinheitlichen.
        .map((f) => File(f.path.replaceAll(r'\', '/')))
        .where((f) => f.path.endsWith('.dart'))
        // Temporary, explicitly German-only developer calibration UI.
        .where((f) => !f.path.startsWith('lib/dev/analyzer_selftest'));

/// Entfernt Kommentare (// … bis Zeilenende, nicht in Strings – vereinfacht).
String _stripComments(String s) => s
    .split('\n')
    .map((l) {
      final t = l.trimLeft();
      if (t.startsWith('//')) return '';
      return l;
    })
    .join('\n');

final _trCall = RegExp(
  r"\btrf?\(\s*((?:'(?:[^'\\]|\\.)*'\s*)+)[,)]",
  multiLine: true,
);

Set<String> _placeholders(String s) =>
    RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  test('Custom Mode labels are translated without legacy visible names', () {
    final previous = AppLang.instance.language;
    try {
      for (final language in AppLanguage.values) {
        AppLang.instance.language = language;
        expect(
          tr('Eigene\nAnsicht'),
          language == AppLanguage.de ? 'Eigene\nAnsicht' : 'Custom\nMode',
        );
        expect(
          tr('Eigene Ansicht einrichten'),
          language == AppLanguage.de
              ? 'Eigene Ansicht einrichten'
              : 'Configure Custom Mode',
        );
        expect(
          trf('Eigene Ansicht {n} überschreiben?', {'n': 2}),
          language == AppLanguage.de
              ? 'Eigene Ansicht 2 überschreiben?'
              : 'Overwrite Custom Mode setup 2?',
        );
      }
      final legacy = RegExp(r'\bEasy(?:Mode)?\b', caseSensitive: false);
      expect(stringsEn.keys.where(legacy.hasMatch), isEmpty);
      expect(stringsEn.values.where(legacy.hasMatch), isEmpty);
      for (final file in _dartFiles()) {
        for (final match in _trCall.allMatches(
          _stripComments(file.readAsStringSync()),
        )) {
          expect(
            legacy.hasMatch(_joinLiterals(match.group(1)!)),
            isFalse,
            reason: file.path,
          );
        }
      }
    } finally {
      AppLang.instance.language = previous;
    }
  });

  test('Jeder tr()/trf()-Text hat eine englische Übersetzung', () {
    final missing = <String>[];
    final badPlaceholders = <String>[];
    for (final f in _dartFiles()) {
      final src = _stripComments(f.readAsStringSync());
      for (final m in _trCall.allMatches(src)) {
        final key = _joinLiterals(m.group(1)!);
        final en = stringsEn[key];
        if (en == null) {
          missing.add('${f.path}: "$key"');
        } else if (_placeholders(en).length != _placeholders(key).length ||
            !_placeholders(en).containsAll(_placeholders(key))) {
          badPlaceholders.add('${f.path}: "$key" -> "$en"');
        }
      }
    }
    expect(missing, isEmpty, reason: 'Fehlende Übersetzungen');
    expect(badPlaceholders, isEmpty, reason: 'Platzhalter passen nicht');
  });

  test('Keine deutschen UI-Texte (Umlaute) außerhalb von tr()', () {
    const exempt = {
      'lib/l10n/strings_en.dart',
      'lib/protocol/adi2_params.dart', // Schlüssel, siehe nächster Test
      'lib/eq/eq_model.dart',
    };
    final umlaut = RegExp(r'[äöüÄÖÜß]');
    final hits = <String>[];
    for (final f in _dartFiles()) {
      final path = f.path.replaceAll('\\', '/');
      if (exempt.contains(path)) continue;
      var src = _stripComments(f.readAsStringSync());
      // tr()/trf()-Argumente und debugPrint/Exceptions ausnehmen
      src = src.replaceAll(_trCall, 'tr(_)');
      src = src.replaceAll(RegExp(r"debugPrint\([^;]*\);"), '');
      for (final m in RegExp(r"'((?:[^'\\]|\\.)*)'").allMatches(src)) {
        if (umlaut.hasMatch(m.group(1)!)) hits.add('$path: ${m.group(0)}');
      }
    }
    expect(hits, isEmpty);
  });

  test('Alle Parameternamen und Auswahlwerte sind übersetzt', () {
    final missing = <String>{};
    void check(String s) {
      if (!stringsEn.containsKey(s)) missing.add(s);
    }

    for (final v in Adi2Variant.values) {
      for (final d in [
        ...inputParams(v),
        ...outputParams(v, phones: false),
        ...outputParams(v, phones: true),
        ...deviceParams(v),
      ]) {
        check(d.name);
        // Tastenbelegung: Funktionsnamen bleiben englisch wie am Gerät.
        if (d.index >= 22 && d.index <= 29 && d.index != 25) continue;
        d.options?.forEach(check);
      }
    }
    for (final b in eqBands) {
      for (final t in b.types) {
        check(t.$1);
      }
    }
    for (final s in exInputRef) {
      check(s);
    }
    expect(missing, isEmpty);
  });

  test('Sprachwechsel übersetzt Parameter und erhält Werte und Schlüssel', () {
    final previous = AppLang.instance.language;
    final polarity = outputParams(
      Adi2Variant.pro,
      phones: false,
    ).firstWhere((d) => d.index == OutIdx.polarity);
    try {
      AppLang.instance.language = AppLanguage.en;
      expect(tr('Lautstärke'), 'Volume');
      expect(polarity.format(0), 'Off');
      expect(polarity.format(2), 'Left');
      expect(polarity.format(99), '99');
      expect(tr('SD Sharp'), 'SD Sharp');
      expect(
        trf('Band {band}, {typ}', {'band': 1, 'typ': tr('Hochpass')}),
        'Band 1, High-pass',
      );
      expect(trf('max. {wert}', {'wert': '−30,0 dBu'}), 'max. −30,0 dBu');

      AppLang.instance.language = AppLanguage.de;
      expect(tr('Lautstärke'), 'Lautstärke');
      expect(polarity.format(0), 'Aus');
      expect(polarity.format(2), 'Links');
      expect(polarity.name, 'Polarität');
      expect(polarity.options, ['Aus', 'Beide', 'Links', 'Rechts']);
      expect(
        trf('Band {band}, {typ}', {'band': 1, 'typ': tr('Hochpass')}),
        'Band 1, Hochpass',
      );
    } finally {
      AppLang.instance.language = previous;
    }
  });
}
