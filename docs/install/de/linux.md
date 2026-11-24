# Remote for ADI-2 unter Linux installieren

[English](../linux.md) · [Zurück zu den Downloads](../../README.de.md#download)

**Datei:** `Remote-for-ADI-2-Linux-1.3.0.AppImage` aus dem [Downloadbereich](../../README.de.md#download).
**Voraussetzung:** Linux-PC (x86_64), z. B. Linux Mint 22 / Ubuntu 24.04, und ein per USB angeschlossener ADI-2. Für WLAN-Steuerung müssen beide Geräte im selben Netzwerk sein.

Remote for ADI-2 vereint Desktop-Oberfläche und Host in einem Programm.

## 1. Herunterladen und starten

1. Das AppImage herunterladen und in einem dauerhaften Ordner ablegen, auch für Autostart.
2. Unter **Dateieigenschaften → Zugriffsrechte** das Ausführen als Programm erlauben. Alternativ im Downloadordner ein Terminal öffnen und ausführen:

   ```sh
   chmod +x Remote-for-ADI-2-Linux-1.3.0.AppImage
   ```

3. Das AppImage per Doppelklick starten. Die Oberfläche öffnet sich und ein Symbol erscheint im Tray.

Unter Mint/Ubuntu folgende Laufzeitpakete installieren, falls sie fehlen:

```sh
sudo apt update
sudo apt install pulseaudio-utils libayatana-appindicator3-1 avahi-daemon
```

- **pulseaudio-utils** stellt `pactl`, `parec` und `pacat` für Analyzer-Aufnahme und Testsignale bereit. Benötigt wird ein funktionierendes PipeWire mit PulseAudio-Kompatibilität oder PulseAudio. `pw-record` aus **pipewire-bin** ist eine alternative Aufnahmequelle; `pactl` bleibt erforderlich.
- **libayatana-appindicator3-1** stellt AppIndicator-Unterstützung für das Tray-Symbol bereit. Die Desktop-Umgebung muss StatusNotifier-/AppIndicator-Symbole unterstützen.
- **avahi-daemon** ermöglicht die Host-Suche im lokalen Netzwerk. Mint/Ubuntu bringt ihn normalerweise mit.
- Meldet das AppImage fehlende FUSE-Unterstützung, unter Mint 22 / Ubuntu 24.04 **libfuse2t64** installieren (`sudo apt install libfuse2t64`). Auf älteren Ubuntu-Versionen heißt das Paket **libfuse2**.

GTK 3, ALSA und eine Desktop-D-Bus-Sitzung müssen verfügbar sein; Mint/Ubuntu bringt sie normalerweise mit. Dateidialoge verwenden **xdg-desktop-portal** und **xdg-desktop-portal-gtk**, die ebenfalls normalerweise vorhanden sind.

## 2. ADI-2 verbinden

1. Den ADI-2 mit einem datenfähigen USB-Kabel anschließen.
2. Am ADI-2 **MIDI Control → ON** einschalten:
   - DAC: **SETUP → Options → Remap Keys / Diag → MIDI Control**
   - ADI-2 Pro / ADI-2/4 Pro: **SETUP → Options → Device Mode / DSD → MIDI Control**
3. Das erkannte Modell in der Oberfläche prüfen. Zum Analyzer-Vergleich mit dem Gerätedisplay Loopback **post FX** auf USB **1/2** wählen. Die Linux-Aufnahme benötigt keine Pegelkalibrierung.

## 3. Oberfläche und Autostart

Die Kopfzeile bietet Desktop, „Nur Gerät“ und Kompakt sowie eigene Analyzer- und Player-Fenster. Die Player-Steuerung benötigt einen **MPRIS**-Player, etwa VLC. Testsignale stehen unter **App-Einstellungen → Testsignale** bereit und funktionieren nur am lokalen ADI-2.

Das Schließen des Fensters lässt das Programm im Tray weiterlaufen. Per Rechtsklick auf das Symbol und **Oberfläche öffnen** zurückkehren. Auch ein erneuter Start des AppImage öffnet die laufende Oberfläche. **Bei Anmeldung starten** im Tray-Menü schaltet Autostart im Hintergrund ohne Fenster ein. **Beenden** beendet das Programm.

## 4. Smartphone koppeln oder anderen Computer steuern

Im Tray-Menü **Client koppeln…** wählen. Am Smartphone **Über Host verbinden** öffnen und den QR-Code scannen oder den Code eingeben. Jedes Gerät einzeln koppeln; bis zu vier Smartphones oder Tablets können gleichzeitig verbunden sein.

Um den ADI-2 an einem anderen Computer zu steuern, dort **Client koppeln…** öffnen. In der Linux-Oberfläche auf **HOST** bzw. **CLIENT** klicken, **Über Host verbinden** öffnen, den anderen Rechner wählen und dessen Code eingeben. **HOST** ist grün für diesen Rechner, **CLIENT** blau für einen anderen Host; die aktive Verbindung ist markiert. **Dieser Rechner** kehrt zum lokalen Host zurück.

Details: [Benutzerhandbuch](../../BENUTZERHANDBUCH.md#linux).

## Updates

Das Programm meldet neue Versionen (abschaltbar). Über das Tray-Menü beenden und das AppImage durch die neue Version ersetzen. Einstellungen und Kopplungen bleiben erhalten. Die neue Datei einmal starten, damit ein eingeschalteter Autostart ihren aktuellen Speicherort verwendet.
