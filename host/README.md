# Remote for ADI-2 Host

Flutter-Hintergrundprogramm für Windows und macOS. Der Host verbindet ein gekoppeltes Smartphone im lokalen WLAN mit dem USB-MIDI-Port des ADI-2. Das Tray-Menü bietet Kopplung, Widerruf, Autostart und Beenden.

**Stufe 1 umgesetzt, auf Hardware ungeprüft.**

- [Entwurf und Einschränkungen](../docs/HOST_PLAN.de.md)
- [English](../docs/HOST_PLAN.md)
- [Prüfergebnisse](../reports/HOST_STEUERUNG_BERICHT.de.md)

Im Verzeichnis `host/` mit `flutter pub get --offline` vorbereiten und auf der Zielplattform über `flutter run -d windows` beziehungsweise `flutter run -d macos` starten. Zum Verteilen ist ein Release-Build samt Signierung/Installation erforderlich.
