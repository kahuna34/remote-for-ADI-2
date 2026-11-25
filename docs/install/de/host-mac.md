# Host auf dem Mac installieren

[English](../host-mac.md) · [Zurück zu den Downloads](../../README.de.md#download)

**Datei:** `Remote-for-ADI-2-Host-macOS-1.3.0.zip` aus dem [Downloadbereich](../../README.de.md#download).
**Voraussetzung:** Mac, an dem der ADI-2 per USB hängt; für WLAN-Steuerung beide Geräte im selben Netzwerk.

Remote for ADI-2 Host bietet eine eigene Oberfläche zur Bedienung des ADI-2 am Computer und ermöglicht die Steuerung per WLAN vom Smartphone, Tablet oder einem anderen Computer. Für die direkte USB-Verbindung zum Smartphone genügt die App.

## 1. Installieren

1. Die Datei entpacken und **Remote for ADI-2 Host** in **Programme** ziehen.
2. Starten. Das Programm ist nicht von Apple signiert, deshalb blockiert macOS den ersten Start: **Systemeinstellungen → Datenschutz & Sicherheit** öffnen und **Trotzdem öffnen** wählen.
3. Das Symbol erscheint in der Menüleiste.

## Oberfläche

Beim normalen Start öffnet sich die Oberfläche. Die Kopfzeile bietet **Desktop**, **Nur Gerät** und **Kompakte Ansicht** sowie eigene Analyzer- und Player-Fenster. Details: [Benutzerhandbuch](../../BENUTZERHANDBUCH.md#desktop-ansichten-und-fenster).

Das Schließen des Fensters lässt den Host im Hintergrund weiterlaufen. Ein Linksklick auf das Symbol öffnet die Oberfläche, ein Rechtsklick das Menü. Ein erneuter Programmstart holt die laufende Oberfläche nach vorn. Autostart über das Symbolmenü startet nur im Hintergrund. **Beenden** im Menü beendet den Host.

Beim ersten Analyzer-Start den Mikrofon-Zugriff für **Remote for ADI-2 Host** erlauben. Er wird für die USB-Aufnahme des ADI-2 benötigt. Bei Ablehnung unter **Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon** erlauben und im Analyzer **Erneut versuchen** wählen.

## 2. Smartphone oder Tablet koppeln

1. Im Host-Menü **Client koppeln…** wählen.
2. In der App **Über Host verbinden** wählen und den QR-Code scannen oder den Code eingeben.
3. Bis zu vier Smartphones oder Tablets können gleichzeitig verbunden sein; jedes einmal koppeln.

Details: [Benutzerhandbuch](../../BENUTZERHANDBUCH.md#steuerung-über-einen-computer-host).

## Anderen Computer steuern

Auf dem anderen Rechner Remote for ADI-2 Host (Mac/Windows) oder Remote for ADI-2 (Linux) starten, den ADI-2 per USB anschließen und **MIDI Control → ON** einschalten. Beide Rechner müssen im selben Netzwerk sein.

Dort **Client koppeln…** im Symbolmenü öffnen. Auf dem steuernden Rechner über **HOST** bzw. **CLIENT** die Seite **Über Host verbinden** öffnen, den anderen Rechner wählen und dessen Code eingeben. **HOST** ist grün für diesen Rechner; **CLIENT** ist blau bei Verbindung mit einem anderen Host. Die aktive Verbindung ist markiert. **Dieser Rechner** wechselt zurück zum eigenen ADI-2.

## Intel-Mac

Flackert die Oberfläche auf einem Intel-Mac oder zeigt schwarze bzw. orange Streifen (zum Beispiel beim schnellen Drücken von Lautstärke + oder −), stattdessen `Remote-for-ADI-2-Host-Intel-Mac-1.3.0.zip` verwenden. Es ist derselbe Host mit einem anderen Grafik-Renderer. Genauso installieren und die vorhandene App ersetzen; Einstellungen und Kopplungen bleiben erhalten. Er läuft auch auf Macs mit Apple-Chip, dort ist aber die normale Version empfohlen.

## Updates

Der Host meldet neue Versionen (abschaltbar). Die neue Version genauso installieren und die alte App in Programme ersetzen. Kopplungen und Einstellungen bleiben erhalten.

## Mit iPhone

AltServer von AltStore kann auf demselben Mac neben dem Host laufen, siehe [iPhone mit AltStore](iphone-altstore.md).
