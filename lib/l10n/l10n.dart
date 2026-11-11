// Sprachumschaltung (Englisch Standard, Deutsch wählbar).
//
// Verwendung: Jeder sichtbare Text wird mit tr('Deutscher Text') bzw.
// trf('Text mit {name}', {'name': wert}) geschrieben. Der deutsche Text ist
// zugleich der Schlüssel; die englische Übersetzung steht in strings_en.dart.
// Fehlt eine Übersetzung, erscheint der deutsche Text (und ein Test schlägt an).

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings_en.dart';

enum AppLanguage {
  en('English'),
  de('Deutsch');

  const AppLanguage(this.label);
  final String label;
}

class AppLang extends ChangeNotifier {
  AppLang._();
  static final AppLang instance = AppLang._();

  AppLanguage language = AppLanguage.en;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString('app_language');
      language = AppLanguage.values.firstWhere(
        (l) => l.name == s,
        orElse: () => AppLanguage.en,
      );
    } catch (_) {}
    notifyListeners();
  }

  Future<void> set(AppLanguage l) async {
    language = l;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_language', l.name);
    } catch (_) {}
  }
}

/// Übersetzt einen deutschen Text in die gewählte Sprache.
String tr(String de, {String? context}) {
  if (AppLang.instance.language == AppLanguage.de) return de;
  return (context == null ? null : stringsEn['$context:$de']) ??
      stringsEn[de] ??
      de;
}

/// Wie [tr], mit Platzhaltern: trf('Preset {n} gespeichert', {'n': 3}).
String trf(String de, Map<String, Object?> args) {
  var s = tr(de);
  for (final e in args.entries) {
    s = s.replaceAll('{${e.key}}', '${e.value}');
  }
  return s;
}
