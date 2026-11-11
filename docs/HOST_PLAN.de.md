# Windows-/macOS-Host

**Stufe 1 am Mac mit Android-Smartphone und ADI-2 DAC geprüft; Windows-Host baut und startet; Smartphone-Test unter Windows noch offen.** [English](HOST_PLAN.md)

## Verbindung und Desktop-Programm

Die mobile App steuert den ADI-2 über WLAN und das eigenständige Flutter-Projekt `host/`. Der Weg ist Smartphone → WebSocket → Host → USB-MIDI → ADI-2. Das Programm „Remote for ADI-2 Host“ läuft unter Windows im Infobereich und unter macOS in der Menüleiste. Beim Start bleibt das Fenster verborgen. Die kleinen Fenster dienen der Kopplung und dem Widerruf von Geräten. Das Schließen dieser Fenster beendet den Host nicht.

Der Host besitzt eine Statusanzeige, Kopplung mit Code und QR-Code, eine Liste gekoppelter Smartphones, Autostart und Beenden. Das App-Symbol stammt aus dem Hauptprojekt. Autostart verwendet unter Windows `reg.exe` und den Run-Schlüssel des aktuellen Benutzers. Unter macOS wird ein LaunchAgent mit `RunAtLoad` geschrieben. Er startet bei der nächsten Anmeldung. Fehler werden im Host-Fenster angezeigt. Für das Schreiben des LaunchAgents ist der separate macOS-Host unsandboxed konfiguriert. Netzwerk-Client- und Server-Entitlements sind gesetzt.

Der Host öffnet USB-MIDI erst nach erfolgreicher Smartphone-Anmeldung. Drei Sekunden nach Sitzungsende wird der Port geschlossen. Eine neue Sitzung innerhalb dieser Frist kann den Port wiederverwenden. Belegte und fehlende USB-Geräte werden gemeldet. Der Host erzeugt keine eigenen Geräteeinstellungen. Während einer Sitzung fragt er zusätzlich den Gerätestand ab, um Änderungen anderer Software an das Smartphone weiterzugeben. Das Verhalten beim parallelen Betrieb der RME-Software muss auf Hardware geprüft werden.

## Windows: Gerätename und Hintergrundstart

Die Gerätezeile im Menü prüft alle fünf Sekunden die MIDI-Geräteliste, ohne einen Port zu öffnen. Erkennung und Verbindungsaufbau verwenden dieselbe Windows-Namensauflösung. Das Ergebnis der PowerShell-/PnP-Abfrage wird zwischengespeichert, solange Namen und IDs der ADI-2-Kandidatenports gleich bleiben; eine andere Reihenfolge oder Änderungen fremder Ports lösen keine Abfrage aus. Bei geänderten Kandidaten oder einem leeren beziehungsweise fehlgeschlagenen Ergebnis wird erneut abgefragt. Ohne Kandidaten wird der Cache verworfen und ohne PnP-Aufruf „Kein ADI-2 erkannt“ angezeigt; Abziehen wird somit bei der nächsten Prüfung sichtbar. Die Menüanzeige entfernt den Portzusatz und erkennt Pro EX weiterhin an der Seriennummer. Der macOS-Pfad über `ioreg` bleibt unverändert.

Der WinMM-MIDI-Port heißt `ADI-2 DAC Midi Port 1` (Babyface: `Babyface Midi Port 1`); wie die PnP-Namen `RME ADI-2 DAC` enthält er keine Seriennummer. Der zweite Name wird bereits von `autoConnectCandidates` erkannt. Der angeschlossene ADI-2 DAC meldet Modell und Seriennummer über `DEVPKEY_Device_BusReportedDeviceDesc` am `MEDIA`-Gerät. Seine hexadezimale Instanzkennung ist eine Windows-Kennung, keine RME-Seriennummer. Der Host fragt den vom Bus gemeldeten Namen am MEDIA-Gerät und, falls verschieden, an dessen physischem USB-Vorfahren ab. Rein numerische Werte aus `DEVPKEY_Device_SerialNumber` oder dem USB-Instanzsuffix bleiben Rückfälle; widersprüchliche Seriennummern werden verworfen.

Der Parser erzeugt `Modell (Seriennummer)` nur bei widerspruchsfreien Daten und bevorzugt den vom Bus gemeldeten Namen. Er ersetzt den MIDI-Portnamen nur bei genau einem ADI-2 mit passendem Modell. Mehrere MEDIA-Einträge desselben USB-Geräts zählen einmal; mehrere ADI-2, unvollständige Daten, Prozessfehler oder ein Timeout nach drei Sekunden behalten den Portnamen bei. Babyface-Ports werden nicht umbenannt. Der ergänzte Name bleibt auch bei einer innerhalb der USB-Schließfrist wiederverwendeten Verbindung erhalten.

Der Windows-Runner hält einen benannten Mutex für die gesamte Prozesslaufzeit. Ein zweiter Start in derselben Windows-Sitzung beendet sich vor dem Start einer weiteren Flutter-Engine oder eines Servers. Ein durch andere Software belegter Standardport verwendet weiterhin den Ausweichport. Scheitert auch dessen Bindung, bleibt das Programm mit Fehlerstatus über das Tray-Menü bedienbar.

Der Runner erzeugt das Hauptfenster ohne Sichtbarkeitsflag und mit `WS_EX_TOOLWINDOW`, sodass auch ein geöffnetes Kopplungsfenster keinen Taskleistenknopf benötigt. Er ruft beim Start kein `Show` auf und fordert einen Flutter-Frame mit `ForceRedraw` an. Dart setzt zusätzlich `skipTaskbar` und `preventClose`; Schließen verbirgt das Fenster. An der Release-Version geprüft: Das Programm startet ohne sichtbares Fenster und ohne Taskleisten-Eintrag, der Server lauscht, ein zweiter Start beendet sich sofort.

Autostart übergibt `reg.exe` getrennte Argumente und einen in Anführungszeichen eingeschlossenen Programmpfad, auch bei Leerzeichen. Die Tests verwenden Prozessersatzfunktionen; ein echter Run-Eintrag wurde nicht gesetzt. Die Anmeldung bleibt ein manueller Test.

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

Windows-Prüfung (Flutter stable, VS Build Tools 2022): `flutter analyze` ohne Befund und `flutter test` grün in Hauptprojekt und Host, `flutter build windows --release` erfolgreich. Der Namensparser liefert am angeschlossenen ADI-2 DAC `ADI-2 DAC (<Seriennummer>)`. Noch manuell zu prüfen: Zusammenspiel mit RME ADI-2 Remote, Smartphone-Test, Autostart nach Neuanmeldung, Firewall-Abfrage.

Auf echter Hardware offen sind Windows-Infobereich, macOS-Menüleiste und verborgener Start, Autostart bei Anmeldung, QR-Kamera und mDNS auf Android/iPhone, WLAN-Wechsel und Ruhezustand, USB-Belegt-Erkennung, tatsächliche Pegel-/Ref-Level-Rückmeldungen aller Modelle sowie paralleler Betrieb mit der RME-Software. Windows muss eingehende Verbindungen für den Host im privaten Netzwerk erlauben. TCP-Port 47321 beziehungsweise der angezeigte Ausweichport und mDNS über UDP 5353 müssen erreichbar sein.

Paketierung, Signierung, Notarisierung, Installation und Updates sind weitere offene Schritte. **Analyzer über Host gehört zu einer späteren Stufe.** Dafür sind Desktop-Loopback-Aufnahme, Kanalrouting, lokale Spektrumsberechnung, Kalibrierung je Aufnahmeweg und die Übertragung zeitlich zuordenbarer Spektrums-/Pegelwerte erforderlich. Die App zeigt dafür derzeit einen Hinweis.
