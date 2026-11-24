# Linux Mint 22.3 / Ubuntu 24.04 (x86_64)

Das Grundgerüst muss auf Linux gebaut und mit einem ADI-2 geprüft werden.
Flutter **3.47.9** verwenden (neuere Versionen sind für den Host noch nicht freigegeben).

```sh
sudo apt update
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev libayatana-appindicator3-dev libasound2-dev \
  libx11-dev libxi-dev pulseaudio-utils pipewire-bin avahi-daemon \
  libfuse2t64 xdg-desktop-portal xdg-desktop-portal-gtk
sudo systemctl enable --now avahi-daemon
```

`libx11-dev` und `libxi-dev` benötigt die von tray_manager/window_manager
verwendete nativeapi-Version. Deren Linux-Tray verwendet StatusNotifierItem
über GDBus, kompatibel mit dem AppIndicator-Bereich von Cinnamon; das
Ayatana-Paket ist für alternative Plugin-Versionen aufgeführt. MIDI läuft
über Dart/FFI und `libasound.so.2`; Bonsoir benutzt Avahi über D-Bus.
GTK/GIO, ALSA, PipeWire mit pipewire-pulse und ein Sitzungs-D-Bus müssen
auch auf dem Zielrechner verfügbar sein. Bei anderen Desktops muss die
StatusNotifier-/AppIndicator-Unterstützung eingeschaltet sein.
Die XDG-Portale ermöglichen die Dateiauswahl; Mint bringt sie in der Regel mit.
Das transitive JNI-Plugin überspringt seinen optionalen Linux-Build ohne JDK;
Java wird für die Linux-Funktionen der App und des Hosts nicht benötigt.

`appimagetool` separat bereitstellen; das Skript lädt keine Werkzeuge herunter.
`libfuse2t64` erlaubt das Starten FUSE-basierter AppImages auf Mint 22.
Alternativ unterstützen viele AppImages `--appimage-extract-and-run`.

Im Repository:

```sh
flutter pub get
flutter analyze
flutter test
(cd host && flutter pub get && flutter analyze && flutter test)
APPIMAGETOOL=/absoluter/pfad/appimagetool tools/linux/build_appimage.sh
```

Optional `FLUTTER=/absoluter/pfad/flutter` setzen. Einzige Release-Ausgabe:
`dist/Remote-for-ADI-2-Linux-<App-Version>.AppImage`. Das Skript baut `host/`
mit Version und Buildnummer aus der App-`pubspec.yaml`. Der eigenständige
Runner unter `linux/` bleibt für Entwickler erhalten.
AppImages behalten das Flutter-Bundle einschließlich eigener nativer Bibliotheken;
GTK, ALSA und Systemdienste bleiben Voraussetzungen des Zielsystems.

„Remote for ADI-2“ verbindet Host und vollständige App-Oberfläche in einem Prozess.
Ein normaler Start öffnet die Oberfläche; `--autostart` startet nur ins Tray.
Erneutes Starten öffnet das Fenster der laufenden Instanz über einen Unix-Socket
unter `$XDG_RUNTIME_DIR/adi2-remote` (privater temporärer Ersatzpfad, falls unset).
Das Fenster-X blendet aus, nur „Beenden“ im Tray beendet das Programm. Größe und
Position werden gespeichert; die anfängliche Größe ist 1200 × 800.
Die Oberfläche spricht ausschließlich mit `127.0.0.1` am tatsächlich gebundenen
Host-Port, mit eigener automatisch erzeugter Kopplung. MIDI, Analyzer-Aufnahme und
MPRIS gehören dem Host. Der lokale Schlüssel erscheint nicht im Kopplungsdialog
und belegt keinen der vier Smartphone-Sitzungsplätze.
Host-Einstellungen werden unter `linux_host.*` aus vorhandenen Werten migriert;
App-Einstellungen bleiben unverändert. Die Sprache `app_language` ist bewusst
eine gemeinsame Einstellung des Prozesses.
Host-Autostart schreibt eine Desktop-Datei unter `$XDG_CONFIG_HOME/autostart`
(sonst `~/.config/autostart`) und bevorzugt den dauerhaften `$APPIMAGE`-Pfad.
Ein aktiver Autostart-Eintrag wird beim Start auf den aktuellen AppImage-Pfad
und das Argument `--autostart` aktualisiert.
Das Log liegt unter `$XDG_STATE_HOME/remote-for-adi2-host/host.log`
(sonst `~/.local/state/remote-for-adi2-host/host.log`).

Audioaufnahme wählt genau eine ADI-2/RME-Quelle ohne Monitor. `parec` wird
bevorzugt, sonst `pw-record`; `pactl` bleibt für die Quellensuche erforderlich.
Die Quelle wird auf 100 % und nicht stumm gesetzt. Linux wendet keine gespeicherten
Kalibrier-Offsets an. `parec` nutzt 10 ms Latenz und 5 ms Prozesszeit; ein Ringpuffer
begrenzt den Rückstau auf 250 ms und gibt ungefähr 60-mal pro Sekunde Daten ab.
Bei Überlauf werden die ältesten Stereoframes verworfen. Standardgeräte werden
nicht umgestellt.
Player-Steuerung benötigt einen MPRIS-fähigen Player (z. B. VLC).
Updates öffnen den Download im Browser; anschließend das AppImage manuell ersetzen.

Vor Freigabe auf Mint prüfen: kombinierter Release-Build und AppImage,
normaler Start/Autostart, Zweitstart (auch gleichzeitig), Tray, Fenster-X,
Fensterposition nach Neuanmeldung und Kopplung parallel zu vier Smartphones,
USB-MIDI-An-/Abstecken, flüssige Aufnahme und Einheitsverstärkung samt Abbruch bei Trennung,
`pw-record`-Fallback, MPRIS mit Datei-/HTTP-Covern und Player-Wechsel,
mDNS mit und ohne avahi-daemon sowie Browser-Download.

Referenzen: [PipeWire pw-cat](https://docs.pipewire.org/page_man_pw-cat_1.html),
[MPRIS](https://specifications.freedesktop.org/mpris/latest/Player_Interface.html).
