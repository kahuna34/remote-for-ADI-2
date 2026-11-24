# Remote for ADI-2 Host

Flutter-Hintergrundprogramm für Windows und macOS. Der Host verbindet ein gekoppeltes Smartphone im lokalen WLAN mit dem USB-MIDI-Port des ADI-2. Das Tray-Menü bietet Kopplung, Widerruf, Autostart und Beenden.

**Stufe 1 umgesetzt, auf Hardware ungeprüft.**

- [Entwurf und Einschränkungen](../docs/HOST_PLAN.de.md)
- [English](../docs/HOST_PLAN.md)
- [Prüfergebnisse](../reports/HOST_STEUERUNG_BERICHT.de.md)

Im Verzeichnis `host/` mit `flutter pub get --offline` vorbereiten und auf der Zielplattform über `flutter run -d windows` beziehungsweise `flutter run -d macos` starten. Zum Verteilen ist ein Release-Build samt Signierung/Installation erforderlich.

Der Host enthält unter macOS und Windows nun auch die Oberfläche „Remote for
ADI-2“. Ein manueller Start oder Linksklick auf das Tray-/Menüleistensymbol öffnet
sie; Schließen blendet sie aus. Rechtsklick zeigt das Host-Menü. `--autostart`
startet nur im Hintergrund. Analyzer und Player können als eigene Fenster laufen.
Native Fenster-, Einzelinstanz-, Audio- und Autostart-Prüfungen auf den
Zielplattformen stehen für diese Erweiterung noch aus.

Öffentliche Mac-/Windows-Pakete **aus dem Repository-Stamm** bauen:

```sh
dart tools/build_public_host.dart macos
# Auf Windows:
dart tools/build_public_host.dart windows
```

Das Werkzeug benötigt Flutter 3.47.9 und bereits aufgelöste Abhängigkeiten im
Pub-Cache (`flutter pub get` im Stamm und in `host/`). Es verwendet `FLUTTER_ROOT`
oder `flutter` im PATH und baut standardmäßig Release. Weitere Flutter-Buildoptionen
wie `--debug` sind möglich. Fertige Produkte stehen wie bisher unter
`host/build/macos` bzw. `host/build/windows`; diese generierten Verzeichnisse
werden durch den erfolgreichen öffentlichen Build ersetzt.

Dazu wird eine temporäre Quellkopie ohne EQ-Bibliotheksdaten und mit deaktivierter
Bibliotheksfunktion erzeugt. Das ist erforderlich, weil Flutter auch Assets der
App-Pfadabhängigkeit automatisch bündelt. Ein gewöhnlicher Entwicklungsbuild mit
`flutter build` kann deren lokale EQ-Daten enthalten und ist kein öffentliches
Host-Paket. Die ursprünglichen App-/Linux-Quellen, Versionsnummern sowie Programm-
und Downloadnamen bleiben erhalten. Der Windows-Workflow verwendet das Werkzeug.

Bericht: [Mac-/Windows-Oberfläche](../reports/HOST_OBERFLAECHE_MAC_WIN_BERICHT.de.md).
