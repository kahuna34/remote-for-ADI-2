// Die kompatible API der bereits eingetragenen Desktop-Pakete hält alle
// Fenster- und Tray-Aufrufe an einer Stelle.
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/l10n/l10n.dart';

import 'autostart.dart';
import 'desktop_midi.dart';
import 'host_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLang.instance.load();
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString('host_id');
  if (id == null) {
    id = randomToken(16);
    if (!await prefs.setString('host_id', id)) throw StateError('Host-ID');
  }
  final pairing = HostPairing();
  final saved = jsonDecode(prefs.getString('paired_devices') ?? '[]') as List;
  for (final data in saved) {
    final device = PairedDevice.fromJson(data as Map<String, dynamic>);
    pairing.devices[device.id] = device;
  }
  final midi = DesktopMidi();
  final server = HostServer(
    id: id,
    name: Platform.localHostname,
    pairing: pairing,
    midi: midi,
    persist: () async {
      if (!await prefs.setString(
        'paired_devices',
        jsonEncode(pairing.devices.values.map((d) => d.toJson()).toList()),
      )) {
        throw StateError('Persistenz');
      }
    },
  );
  midi.onLost = server.usbLost;
  String? discoveryError;
  try {
    await server.start();
  } on SocketException catch (error) {
    // Auch wenn der Ausweichport nicht gebunden werden kann, bleibt das
    // Tray-Menü zum Anzeigen des Fehlers und zum Beenden verfügbar.
    discoveryError = trf('Host-Fehler {fehler}', {'fehler': error});
    server.status = discoveryError;
  }
  final broadcast = BonsoirBroadcast(
    printLogs: false,
    service: BonsoirService(
      name: server.name,
      type: hostServiceType,
      port: server.port,
      attributes: {'id': id, 'version': '1'},
    ),
  );
  if (server.port != 0) {
    try {
      await broadcast.initialize().timeout(const Duration(seconds: 5));
      await broadcast.start().timeout(const Duration(seconds: 5));
    } catch (_) {
      discoveryError = tr(
        'Netzwerksuche fehlgeschlagen. Manuelle Adresse verwenden.',
      );
    }
  }
  runApp(
    HostApp(
      server: server,
      midi: midi,
      broadcast: broadcast,
      discoveryError: discoveryError,
    ),
  );
  // Das Fenster erst nach dem Start des Servers einrichten: Auf macOS kann das
  // Fenster-Plugin vor dem ersten Frame warten.
  unawaited(_setupWindow());
}

Future<void> _setupWindow() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setTitle('Remote for ADI-2 Host');
    await windowManager.setSize(const Size(440, 600));
    await windowManager.hide();
  } catch (_) {
    // Ohne Fensterfunktionen bleibt der Host über das Menü erreichbar.
  }
}

class HostApp extends StatefulWidget {
  const HostApp({
    super.key,
    required this.server,
    required this.midi,
    required this.broadcast,
    this.discoveryError,
  });
  final HostServer server;
  final DesktopMidi midi;
  final BonsoirBroadcast broadcast;
  final String? discoveryError;
  @override
  State<HostApp> createState() => _HostAppState();
}

class _HostAppState extends State<HostApp> with TrayListener, WindowListener {
  late final HostAutostart _autostart;
  bool _automatic = false;
  bool _pairing = true;
  String? _error;
  List<String> _addresses = [];
  String? _address;
  Timer? _countdown;
  Timer? _detectTimer;
  String? _adi2;
  bool _detected = false;
  Future<void> _menuWork = Future.value();
  HostServer get server => widget.server;

  @override
  void initState() {
    super.initState();
    _error = widget.discoveryError;
    _autostart = HostAutostart(
      platform: Platform.operatingSystem,
      executable: Platform.resolvedExecutable,
      home: Platform.environment['HOME'] ?? '',
    );
    trayManager.addListener(this);
    windowManager.addListener(this);
    server.addListener(_changed);
    unawaited(_detect());
    _detectTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_detect()),
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/host.ico' : 'assets/host.png',
      );
      await trayManager.setToolTip('Remote for ADI-2 Host');
      _automatic = await _autostart.enabled();
      _addresses = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .toList();
      _address = _addresses.firstOrNull;
      await _menu();
      if (mounted) setState(() {});
    } catch (e) {
      await _showError(trf('Host-Fehler {fehler}', {'fehler': e}));
    }
  }

  /// Prüft regelmäßig, ob und welcher ADI-2 angeschlossen ist.
  Future<void> _detect() async {
    String? found;
    try {
      found = await widget.midi.detect();
    } catch (_) {
      found = null;
    }
    if (_detected && found == _adi2) return;
    _detected = true;
    _adi2 = found;
    if (mounted) unawaited(_menu());
  }

  void _changed() {
    if (mounted) setState(() {});
    unawaited(_menu());
  }

  Future<void> _menu() {
    _menuWork = _menuWork
        .catchError((Object _) {})
        .then(
          (_) => trayManager.setContextMenu(
            Menu(
              items: [
                MenuItem(
                  label: server.connectedName == null
                      ? tr(server.status)
                      : '${tr(server.status)} · ${server.connectedName}',
                  // Ohne Aktion, aber nicht deaktiviert: sonst stellt das
                  // System die Zeile grau dar.
                ),
                MenuItem(
                  label: !_detected
                      ? tr('Suche ADI-2 …')
                      : _adi2 == null
                      ? tr('Kein ADI-2 erkannt')
                      : trf('ADI-2 erkannt: {name}', {'name': _adi2!}),
                  // Ohne Aktion, aber nicht deaktiviert: sonst stellt das
                  // System die Zeile grau dar.
                ),
                MenuItem.separator(),
                MenuItem(key: 'pair', label: tr('Smartphone koppeln…')),
                MenuItem(key: 'devices', label: tr('Gekoppelte Geräte…')),
                MenuItem.checkbox(
                  key: 'autostart',
                  label: Platform.isWindows
                      ? tr('Mit Windows starten')
                      : tr('Bei Anmeldung starten'),
                  checked: _automatic,
                ),
                MenuItem.separator(),
                MenuItem(key: 'quit', label: tr('Beenden')),
              ],
            ),
          ),
        );
    return _menuWork;
  }

  Future<void> _show(bool pairing) async {
    if (pairing) server.pairing.issue();
    setState(() => _pairing = pairing);
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _showError(String error) async {
    if (mounted) setState(() => _error = error);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() {
    windowManager.hide();
    _countdown?.cancel();
  }

  @override
  void onTrayIconMouseDown() => unawaited(trayManager.popUpContextMenu());
  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());
  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'pair':
        await _show(true);
      case 'devices':
        await _show(false);
      case 'autostart':
        try {
          await _autostart.setEnabled(!_automatic);
          _automatic = await _autostart.enabled();
        } catch (e) {
          await _showError(
            trf('Autostart fehlgeschlagen {fehler}', {'fehler': e}),
          );
        }
        await _menu();
      case 'quit':
        await server.stop();
        if (widget.broadcast.isReady) await widget.broadcast.stop();
        await trayManager.destroy();
        await windowManager.destroy();
        exit(0);
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _detectTimer?.cancel();
    server.removeListener(_changed);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expires = server.pairing.expires;
    final valid =
        server.pairing.code != null &&
        expires != null &&
        DateTime.now().isBefore(expires);
    final qr = jsonEncode({
      'type': 'adi2-pair-v1',
      'id': server.id,
      'name': server.name,
      'address': _address,
      'port': server.port,
      'code': server.pairing.code,
    });
    return MaterialApp(
      title: 'Remote for ADI-2 Host',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: Text(
            _pairing ? tr('Smartphone koppeln…') : tr('Gekoppelte Geräte…'),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              server.connectedName == null
                  ? tr(server.status)
                  : '${tr(server.status)} · ${server.connectedName}',
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_pairing) ...[
              if (_addresses.isNotEmpty)
                DropdownButton<String>(
                  value: _address,
                  isExpanded: true,
                  items: _addresses
                      .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                      .toList(),
                  onChanged: (a) => setState(() => _address = a),
                ),
              SelectableText('${_address ?? server.name}:${server.port}'),
              if (valid) ...[
                SelectableText(
                  server.pairing.code!,
                  style: const TextStyle(fontSize: 36, letterSpacing: 8),
                ),
                Text(
                  trf('Noch {n} Sekunden gültig', {
                    'n': expires
                        .difference(DateTime.now())
                        .inSeconds
                        .clamp(0, 120),
                  }),
                ),
                if (_address != null)
                  Center(
                    child: QrImageView(
                      data: qr,
                      size: 210,
                      backgroundColor: Colors.white,
                    ),
                  ),
              ] else
                Text(tr('Code abgelaufen oder verwendet')),
              FilledButton(
                onPressed: () => setState(() {
                  server.pairing.issue();
                }),
                child: Text(tr('Neuer Code')),
              ),
              Text(
                tr(
                  'Stufe 1 überträgt im lokalen Netzwerk ohne Verschlüsselung.',
                ),
              ),
            ] else ...[
              for (final device in server.pairing.devices.values)
                ListTile(
                  title: Text(device.name),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await server.revoke(device.id);
                      } catch (e) {
                        await _showError(
                          trf('Widerruf fehlgeschlagen {fehler}', {
                            'fehler': e,
                          }),
                        );
                      }
                    },
                    child: Text(tr('Widerrufen')),
                  ),
                ),
              if (server.pairing.devices.isEmpty)
                Text(tr('Keine gekoppelten Geräte')),
            ],
          ],
        ),
      ),
    );
  }
}
