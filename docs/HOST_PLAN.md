# Windows/macOS host

**Stage 1 checked on a Mac with an Android smartphone and an ADI-2 DAC; Windows host builds and starts; smartphone test on Windows still pending.** [Deutsch](HOST_PLAN.de.md)

## Connection and desktop application

The mobile app controls the ADI-2 through Wi-Fi and the separate Flutter project in `host/`. The route is smartphone → WebSocket → host → USB MIDI → ADI-2. “Remote for ADI-2 Host” runs in the Windows notification area or the macOS menu bar. It starts with its window hidden. Small windows handle pairing and device revocation. Closing a window keeps the background application running.

The tray menu provides status, code/QR pairing, paired smartphones, start at login and quit. The icon comes from the main project. Windows autostart uses `reg.exe` and the current user's Run registry key. macOS writes a LaunchAgent with `RunAtLoad` for the next login. Failures appear in the host window. The separate macOS host is configured without App Sandbox so it can write the LaunchAgent. Network client and server entitlements are present.

USB MIDI opens only after a paired smartphone authenticates. Up to four smartphones/tablets can authenticate simultaneously; each must be paired separately, even while other sessions are active. It closes three seconds after the last session ends. All sessions share one port and, on Windows, one open MIDI helper process. A new session during this grace period can reuse the port. Missing and busy devices are reported. The host originates no device settings. During a session it also polls the device state to forward changes made by other software to the smartphone. Coexistence with the RME software requires hardware validation.

## Windows: device names and background launch

On Windows 11 24H2 with Windows MIDI Services (`MidiSrv`) and the RME driver, a running process can retain its initial WinMM port list after USB removal or insertion. A fresh process sees the correct ports. The previous name cache and three-second PowerShell timeout could therefore leave the menu stale and omit the serial number.

Every five seconds, the host now reads a fresh in-process SetupAPI snapshot: `SetupDiGetClassDevsW` with `GUID_DEVCLASS_MEDIA` and `DIGCF_PRESENT`, then `SetupDiEnumDeviceInfo`. `SPDRP_FRIENDLYNAME` must match `^(RME\s+)?ADI-2`; `SetupDiGetDevicePropertyW` reads `DEVPKEY_Device_BusReportedDeviceDesc` as `DEVPROP_TYPE_STRING`, providing `ADI-2 DAC (<serial number>)`. A missing description falls back to the friendly name without hiding the present device. The USB instance ID is never treated as a serial number on this path. PnP presence controls the menu even when WinMM disagrees. Pro EX recognition still uses the serial number. No MIDI port is opened. The native query is designed for the <50 ms polling budget; its actual duration must be measured on Windows. PowerShell is only an API-failure fallback, with a ten-second timeout. macOS/CoreMIDI and `ioreg` are unchanged.

The host detects connection and removal itself and opens MIDI freshly when the first session needs a closed port, without terminating or restarting itself. The tray icon stays present. WinMM input/output runs in `adi2_midi.exe` next to `adi2_host.exe`, compiled with Flutter's Dart SDK. A fresh `list` process returns JSON input/output names; each `open <name>` launches a fresh process with both directions of the selected ADI-2 port. The host never enumerates WinMM in its own process. SetupAPI remains authoritative after it has seen the device. If PnP cannot expose an ADI-2 name, detection uses fresh helper lists (`windowsPnpUnreliable`), including a device connected later.

The helper uses a message-only callback window in a separate Dart isolate (`CALLBACK_WINDOW`), eight prepared input buffers and the shared pure Dart `SysexAssembler`. Short messages retain their actual lengths. Input and output headers stay allocated until returned/unprepared; output completes via `MM_MOM_DONE`. There is no MIDI polling timer or added transmission delay. Stdin/stdout carry one hex-encoded MIDI message per line, flushed immediately. The first output is `ok <name>` or `error <code> <text>` (`busy`, `missing`, `io`); `lost` reports removal or transport errors. EOF on the parent-owned stdin pipe also handles parent death and closes the ports. The host closes stdin and kills an unresponsive helper after two seconds. SetupAPI removal also uses `onLost` / `usb_missing`.

`Process.start` uses normal mode without a shell, keeping pipes open. Dart's Windows runtime sets `CREATE_NO_WINDOW` in this mode, so the console-subsystem helper cannot show a console when launched by the GUI host. The callback window itself is message-only and invisible. The runner owns `Local\\RemoteForAdi2Host.SingleInstance`; duplicate launches exit immediately without waiting. Pairings, settings, the server and tray remain in the original host process. No administrator privileges or firewall changes are requested. Windows CI compiles the helper, validates its `list` JSON and includes it in the ZIP. Real WinMM I/O, hotplug, port coexistence and absence of a console window still need Windows hardware validation.

For the firewall prompt, enable Private networks. If only Public was enabled: Windows Security → Firewall & network protection → Allow an app through firewall → Remote for ADI-2 Host → Private. The diagnosis tool reports active network names/categories and warns when enabled inbound allow rules cover only Public while a connection is Private.

The runner creates the main window without a visibility flag and with `WS_EX_TOOLWINDOW`, so an open pairing window also needs no taskbar button. Startup does not call `Show`; `ForceRedraw` requests a Flutter frame. Dart additionally enables `skipTaskbar` and `preventClose`; closing hides the window. Checked on the release build: the program starts without a visible window or taskbar entry, the server listens, and a second launch exits immediately.

Autostart passes separate arguments to `reg.exe` and quotes the executable path, including paths containing spaces. Tests use process substitutes; no real Run entry was set. Login remains a manual test.

## Protocol and access

- Local WebSocket on TCP port 47321, falling back to an OS-assigned port if occupied. mDNS advertises `_adi2remote._tcp`, host ID and actual port. Manual addressing is available.
- JSON envelopes carry complete Base64 SysEx messages. Authenticated messages use strictly consecutive per-direction sequence numbers starting at 1 and HMAC-SHA256. The MAC binds direction, sequence, message type and the exact JSON payload text.
- A six-digit pairing code expires after two minutes and is single-use. Five failed attempts lock it. The QR payload contains version, host ID, host name, selected LAN address, port and code.
- Pairing creates a random 32-byte device key stored on both ends. Host identity and pairings persist across restarts. Authentication binds host ID, smartphone ID, random server challenge and client nonce. Both peers prove key possession and derive a fresh session key.
- Up to four authenticated sessions control simultaneously. Only a fifth authentication receives `busy`; pairing remains available without USB access. Revoking a pairing ends all its active sessions and blocks authentication with that key.
- Stage 1 has **no encryption**. Initial key exchange is also plaintext. Keys use platform SharedPreferences. Encrypted transport and protected credential storage remain open.

Message types are `hello`, `pair`, `paired`, `auth`, `authenticated`, `heartbeat`, `release` and `midi`. Dedicated responses are `not_paired`, `busy`, `usb_missing`, `usb_busy`, `revoked`, `session_expired` and `volume_limited`. Responses before authentication use plain envelopes. All messages after authentication are signed. Invalid MACs, repeated or skipped sequence numbers and malformed frames terminate the connection.

## Volume protection

The host observes output volume, reference level, mute and dim in device responses. Volume and reference level must first be known. Reductions, muting and enabling dim pass immediately. Unmuting and disabling dim require a valid grant.

The foreground smartphone sends a heartbeat every **300 ms**. Its grant expires after **1 s** without a heartbeat. The session is terminated so delayed traffic cannot revive an expired grant. Backgrounding sends `release` and stops app ramps. Grants belong to individual sessions: release, disconnect, heartbeat expiry or revocation removes only that session’s grant and reference-level compensation. Other sessions continue unchanged. Shared device/filter state is reset only when the last session ends, on USB loss or at shutdown. USB loss is reported to every session as `usb_missing`, preserving compatibility with older apps.

The filter directly imports `volTickMs = 50`, `volMinRaw = -1145`, `volMaxRaw = 60` and `riseRateDbPerSec` from `lib/device/volume_guard.dart`. Its adaptive rate is `clamp(2.5 × 10^(−dB/30), 1.5, 20)` dB/s. All clients share elapsed rise time and fractional increments per output, so simultaneous writes cannot multiply the rate. Each incoming write receives at most three 50-ms ticks of increase budget for uneven packet delivery, as before; there is no unbounded accumulation. Clipped targets are discarded without a target queue or catch-up ramp.

Reference-level increases require a grant and must also fit the level budget. The existing app lowers volume before increasing reference level. The filter credits this compensation once within 100 ms only to the session that lowered the volume, using the existing VolumeOptions reference tables. Large uncompensated reference-level jumps are blocked.

Setup and factory-load commands are blocked at this stage because their volume/reference-level changes cannot be predicted safely. Saving setups, names and ordinary parameters pass through. Clipping is reported as `volume_limited`. The outgoing ADI-2 filter accepts messages up to the protocol's 256-byte limit.

### Shared device queries

Device replies are observed once and broadcast to every authenticated session using its own signed envelope. Client Request All messages (including older app probes/readbacks) feed one shared polling cycle rather than being sent separately. Before the first reply, model probes are collected and rotated; afterwards the reported model is used. The existing four quick polls followed by a complete response and the 1.3-second status pause in each ten-second cycle apply once for all clients. Joining a session does not reset this cycle or the volume filter.

Targeted preset/name requests are still needed because Request All excludes stored EQ presets and setup names. They are queued globally, identical queued requests are combined, and an identical in-flight request within 250 ms is combined too. Dispatch waits for response silence; after a targeted request, both transmission and reception must be quiet for 250 ms before the next query. All requests respect the status pause. Ordinary commands continue immediately through the volume filter.

## Mobile app

The existing controller selects USB MIDI or the new host client. USB takes precedence. The host passes the complete USB device name, including its serial number when available. Model, Pro EX, SD-LD and converter detection stay in the controller.

“Connect via host” provides discovered and saved hosts, QR scanning, code pairing and manual address entry. Background discovery refreshes known host IDs' addresses for the next connection. Foreground reconnect attempts run every three seconds. Every new session clears device values, volume ramps and EQ targets and requests a fresh state. Changes from other clients arrive as ordinary device readbacks, using the existing short hold for stale echoes of own writes. When reading stored EQ presets, the controller uses the preceding preset number to exclude other clients’ preset responses from its own capture. It allows five seconds per preset over the host to account for the shared query queue and status pause; USB keeps its two-second timeout. The transport has no replay queue. The header shows HOST and its name using the existing OFFLINE layout rules.

Android adds camera and multicast permissions and a multicast lock during discovery. The main app's macOS target receives no host functionality.

## Verification and remaining work

Protocol, pairing, controller, badge, volume-filter and autostart tests have been added. Stage 1 was checked on a Mac with an Android smartphone and an ADI-2 DAC; Windows, autostart and a Wi-Fi drop during a volume increase remain to be verified.

Windows verification (Flutter stable, VS Build Tools 2022): `flutter analyze` clean and `flutter test` green in the main project and host, `flutter build windows --release` succeeds. On the attached ADI-2 DAC the name parser returns `ADI-2 DAC (<serial number>)`. Still to check manually: coexistence with RME ADI-2 Remote, smartphone test, autostart after sign-in, firewall prompt.

Hardware validation remains for the Windows notification area, macOS menu bar and hidden launch, actual login autostart, Android camera and mDNS, Wi-Fi changes and sleep/resume, USB busy detection, actual level/reference readbacks across models, and parallel RME software use. Windows must allow incoming connections for the host on private networks. TCP 47321 or the displayed fallback port and mDNS over UDP 5353 must be reachable.

Packaging, signing, notarization, installation and updates remain open. **Analyzer via host belongs to a later stage.** That requires desktop loopback capture, channel routing, local spectrum processing, per-capture-path calibration and time-identifiable spectrum/level frames. The app currently displays a notice for this mode.
