# Host unter Windows installieren

[English](../host-windows.md) · [Zurück zu den Downloads](../../README.de.md#download)

**Datei:** `Remote-for-ADI-2-Host-Windows-Setup-<Version>.exe` aus dem [Downloadbereich](../../README.de.md#download).
**Voraussetzung:** Windows-PC (64 Bit), an dem der ADI-2 per USB hängt; Smartphone/Tablet und PC im selben Netzwerk.

Den Host braucht man nur, um den ADI-2 per WLAN über den Computer zu steuern. Für die direkte USB-Verbindung zum Smartphone genügt die App.

## 1. Installieren

1. **Remote-for-ADI-2-Host-Windows-Setup-<Version>.exe** ausführen. Das Setup installiert für dein Benutzerkonto ohne Administratorrechte, legt **Remote for ADI-2 Host** im Startmenü an und schaltet **Mit Windows starten** ein.
2. Warnt SmartScreen: **Weitere Informationen → Trotzdem ausführen**.
3. Das Symbol erscheint im Infobereich der Taskleiste, eventuell hinter dem Pfeil (^).
4. Fragt die Windows-Firewall, **Private Netzwerke** erlauben. Wurde der Zugriff nur für öffentliche Netzwerke erteilt: **Windows-Sicherheit → Firewall- & Netzwerkschutz → Zugriff von App durch Firewall zulassen** und bei **Remote for ADI-2 Host** **Privat** anhaken.

Der Host erkennt, wenn Geräte angeschlossen oder getrennt werden, und öffnet für jede Sitzung über ein kleines Hilfsprogramm eine frische MIDI-Verbindung. Er läuft weiter und sein Symbol bleibt sichtbar.

## 2. Smartphone oder Tablet koppeln

1. Im Host-Menü **Smartphone koppeln…** wählen.
2. In der App **Über Host verbinden** wählen und den QR-Code scannen oder den Code eingeben.
3. Bis zu vier Smartphones oder Tablets können gleichzeitig verbunden sein; jedes einmal koppeln.

Details: [Benutzerhandbuch](../../BENUTZERHANDBUCH.md#steuerung-über-einen-computer-host).

## Updates und Deinstallation

Der Host meldet neue Versionen (abschaltbar). Das neue Setup ausführen; Kopplungen und Einstellungen bleiben erhalten. Deinstallieren unter **Einstellungen → Apps → Installierte Apps**.

## Mit iPhone

AltServer von AltStore kann auf demselben PC neben dem Host laufen, siehe [iPhone mit AltStore](iphone-altstore.md).
