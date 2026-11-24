# Host unter Windows installieren

[English](../host-windows.md) · [Zurück zu den Downloads](../../README.de.md#download)

**Datei:** `Remote-for-ADI-2-Host-Windows-Setup-1.3.0.exe` aus dem [Downloadbereich](../../README.de.md#download).
**Voraussetzung:** Windows-PC (64 Bit), an dem der ADI-2 per USB hängt; für WLAN-Steuerung beide Geräte im selben Netzwerk.

Remote for ADI-2 Host bietet eine eigene Oberfläche zur Bedienung des ADI-2 am Computer und ermöglicht die Steuerung per WLAN vom Smartphone, Tablet oder einem anderen Computer. Für die direkte USB-Verbindung zum Smartphone genügt die App.

## 1. Installieren

1. **Remote-for-ADI-2-Host-Windows-Setup-1.3.0.exe** ausführen. Das Setup installiert für dein Benutzerkonto ohne Administratorrechte, legt **Remote for ADI-2 Host** im Startmenü an und schaltet **Mit Windows starten** ein.
2. Warnt SmartScreen: **Weitere Informationen → Trotzdem ausführen**.
3. Das Symbol erscheint im Infobereich der Taskleiste, eventuell hinter dem Pfeil (^).
4. Fragt die Windows-Firewall, **Private Netzwerke** erlauben. Wurde der Zugriff nur für öffentliche Netzwerke erteilt: **Windows-Sicherheit → Firewall- & Netzwerkschutz → Zugriff von App durch Firewall zulassen** und bei **Remote for ADI-2 Host** **Privat** anhaken.

Der Host erkennt, wenn Geräte angeschlossen oder getrennt werden, und öffnet für jede Sitzung über ein kleines Hilfsprogramm eine frische MIDI-Verbindung. Er läuft weiter und sein Symbol bleibt sichtbar.

## Oberfläche

Beim normalen Start öffnet sich die Oberfläche. Die Kopfzeile bietet **Desktop**, **Nur Gerät** und **Kompakte Ansicht** sowie eigene Analyzer- und Player-Fenster. Details: [Benutzerhandbuch](../../BENUTZERHANDBUCH.md#desktop-ansichten-und-fenster).

Das Schließen des Fensters lässt den Host im Hintergrund weiterlaufen. Ein Linksklick auf das Symbol öffnet die Oberfläche, ein Rechtsklick das Menü. Ein erneuter Programmstart holt die laufende Oberfläche nach vorn. Autostart über das Symbolmenü startet nur im Hintergrund. **Beenden** im Menü beendet den Host.

## 2. Smartphone oder Tablet koppeln

1. Im Host-Menü **Client koppeln…** wählen.
2. In der App **Über Host verbinden** wählen und den QR-Code scannen oder den Code eingeben.
3. Bis zu vier Smartphones oder Tablets können gleichzeitig verbunden sein; jedes einmal koppeln.

Details: [Benutzerhandbuch](../../BENUTZERHANDBUCH.md#steuerung-über-einen-computer-host).

## Anderen Computer steuern

Auf dem anderen Rechner Remote for ADI-2 Host (Mac/Windows) oder Remote for ADI-2 (Linux) starten, den ADI-2 per USB anschließen und **MIDI Control → ON** einschalten. Beide Rechner müssen im selben Netzwerk sein.

Dort **Client koppeln…** im Symbolmenü öffnen. Auf dem steuernden Rechner über **HOST** bzw. **CLIENT** die Seite **Über Host verbinden** öffnen, den anderen Rechner wählen und dessen Code eingeben. **HOST** ist grün für diesen Rechner; **CLIENT** ist blau bei Verbindung mit einem anderen Host. Die aktive Verbindung ist markiert. **Dieser Rechner** wechselt zurück zum eigenen ADI-2.

## Updates und Deinstallation

Der Host meldet neue Versionen (abschaltbar). Das neue Setup ausführen; Kopplungen und Einstellungen bleiben erhalten. Deinstallieren unter **Einstellungen → Apps → Installierte Apps**.

## Mit iPhone

AltServer von AltStore kann auf demselben PC neben dem Host laufen, siehe [iPhone mit AltStore](iphone-altstore.md).
