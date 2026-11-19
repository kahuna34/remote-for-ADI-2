# App auf dem iPhone mit AltStore oder SideStore installieren

[English](../iphone-altstore.md) · [Zurück zu den Downloads](../../README.de.md#iphone)

Die iPhone-App gibt es nicht im App Store. AltStore und SideStore installieren sie mit deiner eigenen Apple-ID und signieren sie regelmäßig neu. Eine kostenlose Apple-ID genügt.

**Dateien:** `Remote-for-ADI-2-iPhone-<Version>.ipa` oder die AltStore-Quelle aus dem [iPhone-Downloadbereich](../../README.de.md#iphone).
**Voraussetzung:** iPhone mit iOS 15 oder neuer, eine Apple-ID, ein Mac oder Windows-PC für die einmalige Einrichtung.

Gut zu wissen:

- Mit einer kostenlosen Apple-ID gilt die Signatur **7 Tage**. AltStore erneuert sie automatisch, solange AltServer auf deinem Computer läuft und iPhone und Computer im selben WLAN sind. Läuft sie ab, öffnet sich die App erst nach dem Erneuern wieder; die Einstellungen bleiben erhalten.
- Eine kostenlose Apple-ID erlaubt **3 solcher Apps** gleichzeitig; AltStore bzw. SideStore zählt selbst als eine.
- In der EU **AltStore Classic** (mit AltServer) verwenden, nicht AltStore PAL.

## Weg A: AltStore mit AltServer (empfohlen)

AltServer läuft wie Remote for ADI-2 Host im Hintergrund auf deinem Mac oder PC; beide können nebeneinander laufen.

### 1. AltServer auf dem Computer installieren

1. AltServer von der offiziellen Seite **[altstore.io](https://altstore.io)** laden und der Anleitung für [macOS](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) oder [Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) folgen.
   - Windows: AltServer braucht **iTunes** und **iCloud** von Apples Website (nicht die Versionen aus dem Microsoft Store).
2. AltServer starten; das Symbol erscheint in der Menüleiste (Mac) bzw. im Infobereich (Windows).

### 2. AltStore auf dem iPhone installieren

1. iPhone per USB anschließen, entsperren und **Diesem Computer vertrauen** tippen.
2. Mac: im Finder das iPhone auswählen und **Dieses iPhone im WLAN anzeigen** einschalten. Windows: in iTunes das iPhone auswählen und **Mit diesem iPhone über WLAN synchronisieren** einschalten. Damit klappt das Erneuern per WLAN.
3. Auf das AltServer-Symbol klicken → **Install AltStore** → dein iPhone wählen und mit deiner Apple-ID anmelden.
4. Am iPhone (ab iOS 16): **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** → einschalten, Neustart, **Aktivieren** bestätigen.
5. **Einstellungen → Allgemein → VPN und Geräteverwaltung** → deine Apple-ID → **Vertrauen**.

### 3. Remote for ADI-2 installieren

**Über die Quelle (Updates erscheinen in AltStore):**

1. AltStore öffnen → **Sources** → **+**.
2. `https://raw.githubusercontent.com/kahuna34/remote-for-ADI-2/main/apps.json` eingeben und hinzufügen.
3. Die Quelle öffnen, **Remote for ADI-2** wählen → **Free** / **Install**.

**Oder mit der IPA-Datei:**

1. `Remote-for-ADI-2-iPhone-<Version>.ipa` in Safari auf dem iPhone herunterladen (landet in **Dateien → Downloads**).
2. AltStore → **My Apps** → **+** → die IPA wählen.

### 4. Laufend halten

AltStore erneuert die App im Hintergrund, wenn AltServer läuft und beide im selben WLAN sind. Von Hand: AltStore → **My Apps** → **Refresh All**.

## Weg B: SideStore

SideStore funktioniert wie AltStore, erneuert die App aber direkt auf dem iPhone, nach der einmaligen Einrichtung ohne Computer. Die Einrichtung ist technischer (Pairing-Datei und eine lokale VPN-App). Der offiziellen Anleitung auf **[docs.sidestore.io](https://docs.sidestore.io)** folgen, dann die Quelle oben unter **Sources** hinzufügen oder die IPA unter **My Apps → +** installieren.

## ADI-2 verbinden

- **Direkt per USB:** iPhone mit USB-C: USB-C-Kabel zum ADI-2. iPhone mit Lightning: Apple **Lightning auf USB 3 Kamera-Adapter** (mit Stromversorgung) plus USB-Kabel.
- Am ADI-2 **MIDI Control** einschalten (DAC: **SETUP → Options → Remap Keys / Diag → MIDI Control**; Pro-Modelle: **SETUP → Options → Device Mode / DSD → MIDI Control**).
- **Per WLAN:** über Remote for ADI-2 Host auf [Mac](host-mac.md) oder [Windows](host-windows.md).

Besonderheiten am iPhone: Die Player-Leiste zeigt Apple Music, das auf dem iPhone läuft (bzw. den Player des Hosts bei Verbindung über den Host). Die Lautstärketasten des iPhones steuern den ADI-2 bei Verbindung über den Host.
