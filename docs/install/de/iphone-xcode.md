# App auf dem iPhone mit Xcode installieren

[English](../iphone-xcode.md) · [Zurück zu den Downloads](../../README.de.md#iphone)

Für Mac-Nutzer mit Xcode: Ein Skript baut die App auf deinem Mac und installiert sie auf dem angeschlossenen iPhone. AltStore ist nicht nötig.

**Datei:** `Remote-for-ADI-2-iPhone-Xcode-1.3.0.zip` aus dem [iPhone-Downloadbereich](../../README.de.md#iphone).
**Voraussetzung:** Mac mit Xcode (kostenlos im App Store) und etwa 5 GB freiem Speicher, eine Apple-ID (eine kostenlose genügt), iPhone mit iOS 15 oder neuer und ein USB-Kabel. Der erste Lauf dauert etwa 15–30 Minuten, spätere wenige Minuten.

## Einmalige Vorbereitung

1. Xcode einmal starten und die angebotenen Komponenten installieren, auch **iOS**.
2. **Xcode → Einstellungen → Accounts → +** → Apple Account → anmelden. Dein Team wählen → **Manage Certificates…** → **+** → **Apple Development**.
3. iPhone per USB anschließen, entsperren und **Diesem Computer vertrauen** tippen.
4. Am iPhone (ab iOS 16): **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** → einschalten, Neustart, **Aktivieren** bestätigen.
5. Flutter: Das Skript bietet beim ersten Lauf an, es nach `~/development/flutter` zu laden (ca. 1,5 GB). Alternativ vorher mit `brew install --cask flutter` installieren.

## Installieren

1. Die Datei entpacken.
2. Rechtsklick auf **Installieren.command** → **Öffnen** → **Öffnen**. (Nur beim ersten Mal nötig; blockiert macOS trotzdem: **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen**.)
3. Ein Terminalfenster zeigt die Schritte 1/6 bis 6/6. Fragt macOS nach dem Schlüsselbund-Passwort, dein Mac-Passwort eingeben und **Immer erlauben** wählen.
4. Beim ersten Mal am iPhone: **Einstellungen → Allgemein → VPN und Geräteverwaltung** → deine Apple-ID → **Vertrauen**. Dann **Remote for ADI-2** öffnen.

## Gut zu wissen

- Mit einer kostenlosen Apple-ID läuft die App **7 Tage**; danach iPhone anschließen und das Skript erneut starten. Die Einstellungen bleiben erhalten. Mit einem bezahlten Entwicklerkonto läuft sie ein Jahr.
- Neue Version: das neue Paket entpacken und **Installieren.command** erneut starten.
- Schlägt das Bauen fehl, stehen Details in `build/xcodebuild.log`; bitte an ein [Issue](https://github.com/kahuna34/remote-for-ADI-2/issues) anhängen.
- ADI-2 verbinden: siehe [iPhone mit AltStore → ADI-2 verbinden](iphone-altstore.md#adi-2-verbinden).
