# Privacy policy

Remote for ADI-2 and Remote for ADI-2 Host

Last updated: 2026-11-12. Responsible: Markus Rass

No account, advertising, analytics or tracking services. The software does not send data to the developer.

USB MIDI: Control data is exchanged only between the app or host and the ADI-2.

Host: Local network connections use WebSockets (default port 47321, another port if occupied). mDNS exposes the computer name, host ID and port on the network. Pairing uses a code and a saved key. Control data stays on the local network in this use. MIDI and initial pairing are unencrypted; use a trusted network and do not expose the host port to the internet.

Updates: Automatic checks can be disabled and ask api.github.com for the latest release at most once a day. Additional manual checks are possible. GitHub receives the IP address and technical HTTP request data (including the app user agent), no device values or pairing keys. Downloads open in the browser only when requested. GitHub privacy statement: https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement

Camera: Used only to scan the pairing QR code. The app does not save camera images. Permission is needed only when scanning.

Recording permission: Used only for the analyzer with ADI-2 USB audio. PCM audio is processed locally, never saved or sent. For the host analyzer, only encrypted spectrum and level values, capture device identity and calibration identity are sent to requesting paired clients on the local network, never to the internet. During USB route verification, Android default input data may briefly occur; it is discarded without analysis. Permission is needed only when using the analyzer.

Notification access (Android): Used for title, artist, cover, player name and control of the active media session. Media information is displayed in memory only, never saved persistently or sent to the host or developer. If the player supplies an HTTP(S) cover URL, the image is fetched from that URL; the image provider receives the IP address and request data. Local covers are read through Android.

Local storage: SharedPreferences stores language, views and layouts, control and volume protection options, offline device values, analyzer settings and calibrations, serial number markers for the SD-LD test, permission prompts, setup status, update time and version notices, plus host addresses, names, IDs and pairing keys. The host stores its ID, paired smartphone names, IDs and keys, language and update settings. The EQ library is a local JSON file in app storage. Device backups are stored there as JSON in the backups subfolder. Enabled host autostart stores the executable path in a macOS LaunchAgent or the Windows user registry. The manually started analyzer self-test stores local diagnostic reports (at most five) and a recovery journal with device values, but no audio recordings. Deliberately exported or shared EQ presets and backups contain device values and remain at the selected destination.

Deletion and backup: Clearing app data or uninstalling removes local app data. Exported files, pairings on the other device and backup copies must be removed separately. Android backup is not explicitly disabled in the manifest; Android may include app data, including saved pairings, in device backups and restore it. Desktop host preference files may remain after uninstalling.

Contact: Project issues at https://github.com/kahuna34/remote-for-ADI-2/issues
