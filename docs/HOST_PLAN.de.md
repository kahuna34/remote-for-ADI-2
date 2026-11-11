# Windows-/macOS-Host

**Stufe 1 umgesetzt, auf Hardware ungeprüft.** [English](HOST_PLAN.md)

## Verbindung und Desktop-Programm

Die mobile App steuert den ADI-2 über WLAN und das eigenständige Flutter-Projekt `host/`. Der Weg ist Smartphone → WebSocket → Host → USB-MIDI → ADI-2. Das Programm „Remote for ADI-2 Host“ läuft unter Windows im Infobereich und unter macOS in der Menüleiste. Beim Start bleibt das Fenster verborgen. Die kleinen Fenster dienen der Kopplung und dem Widerruf von Geräten. Das Schließen dieser Fenster beendet den Host nicht.

Der Host besitzt eine Statusanzeige, Kopplung mit Code und QR-Code, eine Liste gekoppelter Smartphones, Autostart und Beenden. Das App-Symbol stammt aus dem Hauptprojekt. Autostart verwendet unter Windows `reg.exe` und den Run-Schlüssel des aktuellen Benutzers. Unter macOS wird ein LaunchAgent mit `RunAtLoad` geschrieben. Er startet bei der nächsten Anmeldung. Fehler werden im Host-Fenster angezeigt. Für das Schreiben des LaunchAgents ist der separate macOS-Host unsandboxed konfiguriert. Netzwerk-Client- und Server-Entitlements sind gesetzt.

Der Host öffnet USB-MIDI erst nach erfolgreicher Smartphone-Anmeldung. Drei Sekunden nach Sitzungsende wird der Port geschlossen. Eine neue Sitzung innerhalb dieser Frist kann den Port wiederverwenden. Belegte und fehlende USB-Geräte werden gemeldet. Der Host erzeugt keine eigenen Geräteeinstellungen und führt keine Geräteabfrage selbst aus. Abfragen und Einstellungen stammen aus der App. Das Verhalten beim parallelen Betrieb der RME-Software muss auf Hardware geprüft werden.

## Protokoll und Zugriff

- WebSocket im lokalen Netz auf TCP-Port 47321, bei belegtem Port auf einem vom Betriebssystem vergebenen Ausweichport. mDNS veröffentlicht `_adi2remote._tcp` mit Host-ID und tatsächlichem Port. Eine manuelle Adresse ist ebenfalls möglich.
- JSON-Umschläge transportieren vollständige SysEx-Nachrichten als Base64. Authentifizierte Nachrichten haben pro Richtung eine strikt fortlaufende Sequenznummer ab 1 und HMAC-SHA256. Der HMAC bindet Richtung, Nummer, Nachrichtentyp und den unveränderten JSON-Nutzdatentext.
- Ein sechsstelliger Code gilt zwei Minuten und kann einmal eingelöst werden. Nach fünf Fehlversuchen wird er gesperrt. Der QR-Code enthält Version, Host-ID, Host-Name, ausgewählte LAN-Adresse, Port und Code.
- Die Kopplung erzeugt einen zufälligen 32-Byte-Geräteschlüssel, gespeichert auf beiden Seiten. Host-ID und Kopplungen bleiben über Programmstarts erhalten. Die Anmeldung bindet Host-ID, Smartphone-ID, zufällige Host-Challenge und Client-Nonce ein. Beide Seiten weisen die Kenntnis des Schlüssels nach. Daraus entsteht für jede Verbindung ein neuer Sitzungsschlüssel.
- Eine Sitzung steuert gleichzeitig. Eine zweite Anmeldung erhält `busy`. Widerruf beendet eine aktive Sitzung und verhindert die erneute Anmeldung mit dem alten Schlüssel.
- Stufe 1 bietet **keine Verschlüsselung**. Auch die anfängliche Schlüsselübertragung ist offen. Die Schlüssel liegen in den plattformüblichen SharedPreferences. Verschlüsselter Transport und geschützte Schlüsselablage sind offen.

Die Nachrichtentypen sind `hello`, `pair`, `paired`, `auth`, `authenticated`, `heartbeat`, `release` und `midi`. Eigene Rückmeldungen sind `not_paired`, `busy`, `usb_missing`, `usb_busy`, `revoked`, `session_expired` und `volume_limited`. Fehler vor erfolgreicher Anmeldung werden als einfache Umschläge gesendet. Nach Anmeldung sind auch Rückmeldungen signiert. Falsche HMACs, wiederholte oder übersprungene Sequenzen und ungültige Rahmen beenden die Verbindung.

## Lautstärkeschutz

Der Host liest aus Geräteantworten Volume, Ref Level, Mute und Dim pro Ausgang mit. Lautstärke und Ref Level müssen zunächst bekannt sein. Leiserstellen sowie Mute und Dim einschalten werden sofort durchgereicht. Entstummen und Dim ausschalten erfordern eine gültige Freigabe.

Das Smartphone sendet im Vordergrund alle **300 ms** ein Lebenszeichen. Nach **1 s** ohne Lebenszeichen erlischt die Freigabe. Die Sitzung wird beendet, damit verspätete Pakete keine alte Freigabe erneuern können. Beim Wechsel in den Hintergrund sendet die App `release` und stoppt ihre Rampen. Abriss, USB-Verlust, Widerruf und Programmende verwerfen Freigabe und Filterzustand.

Der Host verwendet `volTickMs = 50`, `volMinRaw = -1145`, `volMaxRaw = 60` und `riseRateDbPerSec` direkt aus `lib/device/volume_guard.dart`. Die adaptive Rate beträgt `clamp(2.5 × 10^(−dB/30), 1.5, 20)` dB/s. Ein Paket erhält höchstens das Budget eines 50-ms-Takts. Häufigere Pakete teilen sich das Zeitbudget. Bruchteile werden mitgeführt. Eine Pause sammelt keine Anhebung für später an. Ein gekappter Rest wird verworfen, ohne Zielpuffer oder nachträgliche Rampe.

Ref-Level-Erhöhungen benötigen eine Freigabe und müssen ebenfalls in das Pegelbudget passen. Die vorhandene App kompensiert einen höheren Ref Level durch vorheriges Absenken. Der Filter berücksichtigt diese Absenkung einmalig innerhalb von 100 ms. Die Pegeltabellen stammen aus der bestehenden VolumeOptions-Logik. Ein unkompensierter großer Ref-Level-Sprung wird gesperrt.

Setup- und Werkseinstellungs-Ladebefehle werden in dieser Stufe gesperrt, weil sie unbekannte Lautstärke-/Ref-Level-Sprünge enthalten können. Setup-Speichern, Leseabfragen, Namen und normale Parameter laufen durch die Brücke. Begrenzungen werden mit `volume_limited` gemeldet. Der Host-Filter bearbeitet ausgehende ADI-2-Nachrichten bis zur protokollgemäßen Grenze von 256 Bytes.

## Mobile App

Der vorhandene Controller verwendet wahlweise den bisherigen MIDI-Transport oder den neuen Host-Client. USB hat Vorrang. Der Host übermittelt den vollständigen USB-Gerätenamen einschließlich verfügbarer Seriennummer. Modell-, Pro-EX-, SD-LD- und Wandlererkennung bleiben im Controller.

„Über Host verbinden“ zeigt gefundene und gespeicherte Hosts, QR-Scan, Code-Kopplung und manuelle Adresse. Die Hintergrundsuche aktualisiert die Adresse bekannter Host-IDs bei der nächsten Verbindung. Wiederverbindungen werden im Vordergrund alle drei Sekunden versucht. Jede neue Sitzung leert Gerätewerte, Rampen und EQ-Ziele und fragt den aktuellen Stand neu ab. Der Transport besitzt keinen Wiederholpuffer. Der Kopf zeigt HOST und den Host-Namen mit denselben Layout-Regeln wie OFFLINE.

Android erhält Kamera- und Multicast-Rechte sowie einen während der Suche gehaltenen Multicast-Lock. iOS erhält lokale Netzwerkfreigabe, Bonjour-Dienst und Kamera-Begründung. Das macOS-Ziel der Haupt-App erhält keine Host-Funktion.

## Prüfstand und offene Punkte

Protokoll-, Kopplungs-, Controller-, Abzeichen-, Filter- und Autostart-Tests sind ergänzt. Stufe 1 wurde am Mac mit einem Android-Smartphone und einem ADI-2 DAC geprüft; Windows, Autostart und ein WLAN-Abbruch während einer Anhebung sind noch zu prüfen.

Auf echter Hardware offen sind Windows-Infobereich, macOS-Menüleiste und verborgener Start, Autostart bei Anmeldung, QR-Kamera und mDNS auf Android/iPhone, WLAN-Wechsel und Ruhezustand, USB-Belegt-Erkennung, tatsächliche Pegel-/Ref-Level-Rückmeldungen aller Modelle sowie paralleler Betrieb mit der RME-Software. Windows muss eingehende Verbindungen für den Host im privaten Netzwerk erlauben. TCP-Port 47321 beziehungsweise der angezeigte Ausweichport und mDNS über UDP 5353 müssen erreichbar sein.

Paketierung, Signierung, Notarisierung, Installation und Updates sind weitere offene Schritte. **Analyzer über Host gehört zu einer späteren Stufe.** Dafür sind Desktop-Loopback-Aufnahme, Kanalrouting, lokale Spektrumsberechnung, Kalibrierung je Aufnahmeweg und die Übertragung zeitlich zuordenbarer Spektrums-/Pegelwerte erforderlich. Die App zeigt dafür derzeit einen Hinweis.
