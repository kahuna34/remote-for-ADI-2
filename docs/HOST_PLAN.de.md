# Computer-Steuerung: Host und Linux

Version **1.3.0 (10)** · [English](HOST_PLAN.md) · [Benutzerhandbuch](BENUTZERHANDBUCH.md#steuerung-über-einen-computer-host)

**Remote for ADI-2 Host** auf Mac und Windows bietet Gerätesteuerung am Computer sowie WLAN-Steuerung von Smartphones, Tablets und anderen Computern. **Remote for ADI-2** unter Linux vereint dieselbe Oberfläche und den Host in einem AppImage.

## Oberfläche und Start

Der normale Start öffnet die Oberfläche. Verfügbar sind Desktop, „Nur Gerät“ und Kompakt sowie eigene Analyzer- und Player-Fenster. Das Schließen des Hauptfensters lässt den Host im Hintergrund weiterlaufen. Erneutes Starten holt die laufende Oberfläche nach vorn. Auf Mac und Windows öffnet Linksklick auf das Symbol die Oberfläche, Rechtsklick das Menü; unter Linux das Tray-Menü verwenden. Autostart startet nur im Hintergrund. Beenden im Symbolmenü beendet das Programm.

## Kopplung und Host zu Host

Den ADI-2 per USB anschließen und MIDI Control einschalten. Im Symbolmenü seines Computers **Client koppeln…** wählen, dann am steuernden Gerät **Über Host verbinden** öffnen. QR-Code scannen oder Code eingeben. Jedes Gerät einzeln koppeln; bis zu vier entfernte Clients können gleichzeitig verbunden sein. Kopplungen lassen sich im Symbolmenü widerrufen.

Auch ein Computer kann unter **Über Host verbinden** einen anderen Rechner wählen und dessen Kopplungscode eingeben. **HOST** in Grün bedeutet diesen Rechner, **CLIENT** in Blau einen anderen Host. Die Host-Auswahl markiert die aktive Verbindung; **Dieser Rechner** kehrt zum lokalen ADI-2 zurück. Der gewählte Host liefert auch Analyzer- und Player-Daten.

## Analyzer und Player

Der Host nimmt ADI-2-USB-Kanäle 1/2 nur bei sichtbarem Analyzer auf und speichert kein Audio. Für den Vergleich mit dem Gerätedisplay Loopback **post FX** verwenden; **post −6 dB** zeigt 6 dB weniger. Lokale Desktop-Oberflächen bieten 30/60 fps, Standard 30.

Am Mac die Mikrofonberechtigung für die USB-Aufnahme erlauben. Windows benötigt Mikrofonzugriff für Desktop-Apps. Die Linux-Aufnahme nutzt PipeWire/PulseAudio, ist bitgenau und benötigt keine Kalibrierung. Der Testsignal-Generator steht nur unter Linux mit lokalem ADI-2 bereit.

Der Mac-Player unterstützt laufende Music- und Spotify-Instanzen und benötigt die Automatisierungsfreigabe. Windows nutzt aktive Mediensitzungen, Linux MPRIS. Metadaten, Cover und Bedienmöglichkeiten hängen vom Player ab.

## Lautstärkeschutz

Der aktuelle Stand kommt vom Gerät. Clients teilen sich die maximale Anstiegsgeschwindigkeit je Ausgang. Die Lautstärkeanhebung eines Clients stoppt bei Trennung oder ausbleibenden Lebenszeichen; nichts wird später nachgeholt. Leiserstellen, Mute und Dim gehen sofort. Das Laden von Geräte-Setups und Werkseinstellungen über den Host ist gesperrt, weil dabei unbekannte Pegel abgerufen werden könnten. App-Grenzen benötigen eine aktive Verbindung und sind kein dauerhafter Hardware-Schutz.

## Installation und Teststand

- [Mac](install/de/host-mac.md), [Windows](install/de/host-windows.md), [Linux](install/de/linux.md).
- Mac-Oberfläche und Analyzer mit ADI-2 Pro geprüft; unter Linux Mint Oberfläche, Analyzer, Player, Autostart und Smartphone-Kopplung mit ADI-2 Pro geprüft.
- Windows-Host mit ADI-2 DAC gebaut und geprüft. Manuelle Prüfungen einzelner Tray-, Anmelde-, Zusatzfenster- und Host-zu-Host-Abläufe stehen noch aus.
- Host zu Host zwischen Linux und Mac geprüft. Andere Plattformkombinationen benötigen noch einen Hardwaretest.
