import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

/// Same wording as the repository privacy notices.
List<String> privacyParagraphs() => [
  tr('Remote for ADI-2 und Remote for ADI-2 Host'),
  tr('Stand: 2026-11-12. Verantwortlich: Markus Rass'),
  tr(
    'Kein Konto, keine Werbung, keine Analyse- oder Tracking-Dienste. Die Software übermittelt keine Daten an den Entwickler.',
  ),
  tr(
    'USB-MIDI: Steuerdaten werden nur zwischen App bzw. Host und ADI-2 ausgetauscht.',
  ),
  tr(
    'Host: Für die Verbindung im lokalen Netzwerk werden WebSockets verwendet (Standardport 47321, bei Belegung ein anderer Port). mDNS macht Computername, Host-ID und Port im Netz sichtbar. Kopplung erfolgt per Code und gespeichertem Schlüssel. Steuerdaten bleiben bei dieser Nutzung im lokalen Netz. MIDI und Erstkopplung sind unverschlüsselt; nutze ein vertrauenswürdiges Netz und gib den Host-Port nicht ins Internet frei.',
  ),
  tr(
    'Updates: Die automatische Prüfung ist abschaltbar und fragt höchstens einmal täglich api.github.com nach dem neuesten Release. Manuelle Prüfungen sind zusätzlich möglich. GitHub erhält die IP-Adresse und technische HTTP-Anfragedaten (unter anderem den App-User-Agent), keine Gerätewerte oder Kopplungsschlüssel. Ein Download öffnet sich nur auf Knopfdruck im Browser. GitHub-Datenschutzerklärung: https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement',
  ),
  tr(
    'Kamera: Nur zum Scannen des Kopplungs-QR-Codes. Die App speichert keine Kamerabilder. Die Berechtigung wird erst beim Scannen benötigt.',
  ),
  tr(
    'Aufnahmeberechtigung: Nur für den Analyzer mit USB-Audio des ADI-2. PCM-Audiodaten werden lokal ausgewertet und nicht gespeichert oder gesendet. Beim Analyzer über Host werden nur verschlüsselte Spektral- und Pegelwerte sowie Aufnahmegerätekennung und Kalibrieridentität an anfordernde gekoppelte Clients im lokalen Netz gesendet, niemals ins Internet. Während der USB-Routenprüfung können kurz Daten des Android-Standardeingangs anfallen; sie werden verworfen und nicht ausgewertet. Die Berechtigung wird erst bei Nutzung des Analyzers benötigt.',
  ),
  tr(
    'Benachrichtigungszugriff (Android): Für Titel, Interpret, Cover, Player-Name und die Steuerung der aktiven Mediensitzung. Medieninformationen werden nur im Arbeitsspeicher angezeigt, nicht dauerhaft gespeichert oder an den Host oder Entwickler gesendet. Liefert der Player eine HTTP(S)-Cover-Adresse, wird das Bild von dieser Adresse geladen; der Bildanbieter erhält dabei IP-Adresse und Anfragedaten. Lokale Cover werden über Android gelesen.',
  ),
  tr(
    'Lokale Speicherung: SharedPreferences enthält Sprache, Ansichten und Layouts, Bedien- und Lautstärkeschutzoptionen, Offline-Gerätewerte, Analyzer-Einstellungen und Kalibrierungen, Seriennummer-Merker für den SD-LD-Test, Freigabehinweise, Einrichtungsstatus, Update-Zeitpunkt und Versionshinweise sowie Host-Adressen, Namen, IDs und Kopplungsschlüssel. Der Host speichert Host-ID, gekoppelte Smartphone-Namen, IDs und Schlüssel sowie Sprache und Update-Einstellungen. Die EQ-Bibliothek liegt als lokale JSON-Datei im App-Speicher. Gerätebackups liegen dort als JSON im Unterordner backups. Ein aktivierter Host-Autostart speichert den Programmpfad in einem macOS-LaunchAgent bzw. der Windows-Benutzerregistrierung. Der manuell gestartete Analyzer-Selbsttest speichert lokale Diagnoseberichte (höchstens fünf) und ein Wiederherstellungsjournal mit Gerätewerten, jedoch keine Audioaufnahmen. Bewusst exportierte oder geteilte EQ-Presets und Backups enthalten Gerätewerte und bleiben am gewählten Ziel.',
  ),
  tr(
    'Löschen und Sicherung: App-Daten löschen oder Deinstallation entfernt die lokalen App-Daten. Exportierte Dateien, Kopplungen auf dem anderen Gerät und Sicherungskopien müssen separat gelöscht werden. Android-Backup ist im Manifest nicht ausdrücklich deaktiviert; Android kann App-Daten einschließlich gespeicherter Kopplungen in die Gerätesicherung aufnehmen und wiederherstellen. Beim Desktop-Host können Einstellungsdateien nach der Deinstallation verbleiben.',
  ),
  tr(
    'Kontakt: Issues im Projekt https://github.com/kahuna34/remote-for-ADI-2/issues',
  ),
];

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppLang.instance,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(tr('Datenschutz'))),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                for (final paragraph in privacyParagraphs())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: SelectableText(
                      paragraph,
                      style: ts(16, height: 1.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
