# Windows/macOS host

**Stage 1 checked on a Mac with an Android smartphone and an ADI-2 DAC; Windows host builds and starts; smartphone test on Windows still pending.** [Deutsch](HOST_PLAN.de.md)

## Connection and desktop application

The mobile app controls the ADI-2 through Wi-Fi and the separate Flutter project in `host/`. The route is smartphone → WebSocket → host → USB MIDI → ADI-2. “Remote for ADI-2 Host” runs in the Windows notification area or the macOS menu bar. It starts with its window hidden. Small windows handle pairing and device revocation. Closing a window keeps the background application running.

The tray menu provides status, code/QR pairing, paired smartphones, start at login and quit. The icon comes from the main project. Windows autostart uses `reg.exe` and the current user's Run registry key. macOS writes a LaunchAgent with `RunAtLoad` for the next login. Failures appear in the host window. The separate macOS host is configured without App Sandbox so it can write the LaunchAgent. Network client and server entitlements are present.

USB MIDI opens only after a paired smartphone authenticates. It closes three seconds after the session ends. A new session during this grace period can reuse the port. Missing and busy devices are reported. The host originates no device settings. During a session it also polls the device state to forward changes made by other software to the smartphone. Coexistence with the RME software requires hardware validation.

## Windows: device names and background launch

Every five seconds, the menu's device row checks the MIDI device list without opening a port. Detection and connection use the same Windows name resolution. The PowerShell/PnP result is cached while the names and IDs of ADI-2 candidate ports remain unchanged; reordering the candidates or changing unrelated ports does not trigger a query. Changed candidates or an empty or failed result trigger a new query. With no candidates, the cache is cleared and “No ADI-2 detected” is shown without a PnP call, so unplugging becomes visible at the next check. The menu removes the port suffix and still recognizes Pro EX by serial number. The macOS path through `ioreg` is unchanged.

The WinMM MIDI port is named `ADI-2 DAC Midi Port 1` (Babyface: `Babyface Midi Port 1`); like the PnP name `RME ADI-2 DAC`, it contains no serial number. `autoConnectCandidates` already recognizes the latter. The attached ADI-2 DAC reports its model and serial number through `DEVPKEY_Device_BusReportedDeviceDesc` on the `MEDIA` device. Its hexadecimal instance identifier is a Windows identifier, not the RME serial number. The host queries this bus-reported name on the MEDIA device and, if different, its physical USB ancestor. Numeric values from `DEVPKEY_Device_SerialNumber` or a purely numeric USB instance suffix remain fallbacks; conflicting serial numbers are rejected.

The parser produces `Model (serial number)` only from consistent data, preferring the bus-reported name. It replaces a MIDI port name only when exactly one ADI-2 is present and its model matches. Multiple MEDIA entries for the same USB device count once; multiple ADI-2 devices, incomplete data, process errors or a three-second timeout preserve the port name. Babyface ports are never renamed. The resolved name also survives reuse of an open USB connection within the closing grace period.

The Windows runner holds a named mutex throughout the process lifetime. A second launch in the same Windows session exits before creating another Flutter engine or server. The fallback port remains available when other software occupies the default port. If binding the fallback port also fails, the application remains accessible through the tray menu with an error status.

The runner creates the main window without a visibility flag and with `WS_EX_TOOLWINDOW`, so an open pairing window also needs no taskbar button. Startup does not call `Show`; `ForceRedraw` requests a Flutter frame. Dart additionally enables `skipTaskbar` and `preventClose`; closing hides the window. Checked on the release build: the program starts without a visible window or taskbar entry, the server listens, and a second launch exits immediately.

Autostart passes separate arguments to `reg.exe` and quotes the executable path, including paths containing spaces. Tests use process substitutes; no real Run entry was set. Login remains a manual test.

## Protocol and access

- Local WebSocket on TCP port 47321, falling back to an OS-assigned port if occupied. mDNS advertises `_adi2remote._tcp`, host ID and actual port. Manual addressing is available.
- JSON envelopes carry complete Base64 SysEx messages. Authenticated messages use strictly consecutive per-direction sequence numbers starting at 1 and HMAC-SHA256. The MAC binds direction, sequence, message type and the exact JSON payload text.
- A six-digit pairing code expires after two minutes and is single-use. Five failed attempts lock it. The QR payload contains version, host ID, host name, selected LAN address, port and code.
- Pairing creates a random 32-byte device key stored on both ends. Host identity and pairings persist across restarts. Authentication binds host ID, smartphone ID, random server challenge and client nonce. Both peers prove key possession and derive a fresh session key.
- One smartphone controls at a time. Another authentication receives `busy`. Revoking a pairing ends its active session and blocks authentication with that key.
- Stage 1 has **no encryption**. Initial key exchange is also plaintext. Keys use platform SharedPreferences. Encrypted transport and protected credential storage remain open.

Message types are `hello`, `pair`, `paired`, `auth`, `authenticated`, `heartbeat`, `release` and `midi`. Dedicated responses are `not_paired`, `busy`, `usb_missing`, `usb_busy`, `revoked`, `session_expired` and `volume_limited`. Responses before authentication use plain envelopes. All messages after authentication are signed. Invalid MACs, repeated or skipped sequence numbers and malformed frames terminate the connection.

## Volume protection

The host observes output volume, reference level, mute and dim in device responses. Volume and reference level must first be known. Reductions, muting and enabling dim pass immediately. Unmuting and disabling dim require a valid grant.

The foreground smartphone sends a heartbeat every **300 ms**. Its grant expires after **1 s** without a heartbeat. The session is terminated so delayed traffic cannot revive an expired grant. Backgrounding sends `release` and stops app ramps. Disconnect, USB loss, revocation and shutdown discard the grant and filter state.

The filter directly imports `volTickMs = 50`, `volMinRaw = -1145`, `volMaxRaw = 60` and `riseRateDbPerSec` from `lib/device/volume_guard.dart`. Its adaptive rate is `clamp(2.5 × 10^(−dB/30), 1.5, 20)` dB/s. Each incoming write receives at most one 50-ms tick of increase budget. Faster packets share the elapsed time budget. Fractional increments carry over. A pause accumulates no future increase. Clipped targets are discarded without a target queue or catch-up ramp.

Reference-level increases require a grant and must also fit the level budget. The existing app lowers volume before increasing reference level. The filter credits this compensation once within 100 ms, using the existing VolumeOptions reference tables. Large uncompensated reference-level jumps are blocked.

Setup and factory-load commands are blocked at this stage because their volume/reference-level changes cannot be predicted safely. Saving setups, read requests, names and ordinary parameters pass through. Clipping is reported as `volume_limited`. The outgoing ADI-2 filter accepts messages up to the protocol's 256-byte limit.

## Mobile app

The existing controller selects USB MIDI or the new host client. USB takes precedence. The host passes the complete USB device name, including its serial number when available. Model, Pro EX, SD-LD and converter detection stay in the controller.

“Connect via host” provides discovered and saved hosts, QR scanning, code pairing and manual address entry. Background discovery refreshes known host IDs' addresses for the next connection. Foreground reconnect attempts run every three seconds. Every new session clears device values, volume ramps and EQ targets and requests a fresh state. The transport has no replay queue. The header shows HOST and its name using the existing OFFLINE layout rules.

Android adds camera and multicast permissions and a multicast lock during discovery. iOS adds local-network, Bonjour and camera descriptions. The main app's macOS target receives no host functionality.

## Verification and remaining work

Protocol, pairing, controller, badge, volume-filter and autostart tests have been added. Stage 1 was checked on a Mac with an Android smartphone and an ADI-2 DAC; Windows, autostart and a Wi-Fi drop during a volume increase remain to be verified.

Windows verification (Flutter stable, VS Build Tools 2022): `flutter analyze` clean and `flutter test` green in the main project and host, `flutter build windows --release` succeeds. On the attached ADI-2 DAC the name parser returns `ADI-2 DAC (<serial number>)`. Still to check manually: coexistence with RME ADI-2 Remote, smartphone test, autostart after sign-in, firewall prompt.

Hardware validation remains for the Windows notification area, macOS menu bar and hidden launch, actual login autostart, Android/iPhone camera and mDNS, Wi-Fi changes and sleep/resume, USB busy detection, actual level/reference readbacks across models, and parallel RME software use. Windows must allow incoming connections for the host on private networks. TCP 47321 or the displayed fallback port and mDNS over UDP 5353 must be reachable.

Packaging, signing, notarization, installation and updates remain open. **Analyzer via host belongs to a later stage.** That requires desktop loopback capture, channel routing, local spectrum processing, per-capture-path calibration and time-identifiable spectrum/level frames. The app currently displays a notice for this mode.
