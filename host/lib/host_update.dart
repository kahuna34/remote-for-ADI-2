import 'dart:convert';

import 'package:adi2_remote/update/update_check.dart';

/// Der gemeinsame Update-Dienst bleibt unverändert. Mit Plattform "other"
/// verwendet er diese für Windows ausgewählte URL und übernimmt weiterhin
/// Versionsvergleich, HTTPS-Prüfung, Zeitplan und Benachrichtigungen.
Future<String> fetchWindowsHostRelease({
  ReleaseFetcher fetcher = fetchLatestRelease,
}) async {
  final data = jsonDecode(await fetcher()) as Map<String, dynamic>;
  final assets = data['assets'] as List? ?? [];
  // Die Auswahl ist hier abgeschlossen; "other" soll kein Asset mehr ersetzen.
  data['assets'] = <Object>[];
  // Dateinamen tragen seit 1.2.2 die Versionsnummer; Setup vor ZIP.
  for (final (prefix, ext) in [
    ('Remote-for-ADI-2-Host-Windows-Setup', '.exe'),
    ('Remote-for-ADI-2-Host-Windows', '.zip'),
  ]) {
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      if (name is! String || !name.startsWith(prefix) || !name.endsWith(ext)) {
        continue;
      }
      final url = Uri.tryParse('${asset['browser_download_url']}');
      if (url?.scheme != 'https' || url!.host.isEmpty) continue;
      data['html_url'] = url.toString();
      // Host und App haben eigene Versionen: die des Setups vergleichen.
      final version = assetVersion(name);
      if (version != null) data['tag_name'] = 'v$version';
      return jsonEncode(data);
    }
  }
  return jsonEncode(data);
}
