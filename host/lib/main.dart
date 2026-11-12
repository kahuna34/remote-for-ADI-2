// Die kompatible API der bereits eingetragenen Desktop-Pakete hält alle
// Fenster- und Tray-Aufrufe an einer Stelle.
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/l10n/l10n.dart';

import 'package:adi2_remote/update/update_check.dart';
import 'package:adi2_remote/update/open_update.dart';

import 'host_info.dart';
import 'host_menu.dart';
import 'host_update.dart';
import 'autostart.dart';
import 'desktop_midi.dart';
import 'host_log.dart';
import 'host_server.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  HostLog.write(
    'Start $hostVersion ${Platform.operatingSystem} args=$arguments',
  );
  FlutterError.onError = (details) {
    HostLog.write('Flutter-Fehler: ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    HostLog.write('Fehler: $error');
    return false;
  };
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
  UpdateCheck? _updates;
  UpdateResult? _availableUpdate;
  String? _updateNotice;
  bool _pairing = true;
  String? _error;
  List<String> _addresses = [];
  String? _address;
  Timer? _countdown;
  Timer? _detectTimer;
  String? _adi2;
  bool _detected = false;
  bool _detecting = false, _exiting = false;
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
      _automatic = await _autostart.refreshEnabledPath();
      // Windows: Autostart beim ersten Start einschalten (abschaltbar im Menü).
      if (Platform.isWindows && !_automatic) {
        final prefs = await SharedPreferences.getInstance();
        if (!(prefs.getBool('autostart_default_applied') ?? false)) {
          try {
            await _autostart.setEnabled(true);
            _automatic = await _autostart.enabled();
            HostLog.write('Autostart standardmäßig eingeschaltet');
          } catch (e) {
            HostLog.write('Autostart fehlgeschlagen: $e');
          }
          await prefs.setBool('autostart_default_applied', true);
        }
      } else if (Platform.isWindows) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('autostart_default_applied', true);
      }
      _addresses = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .toList();
      _address = _addresses.firstOrNull;
      await _menu();
      try {
        await _initializeUpdates();
      } catch (_) {
        // Automatic update failures stay silent.
      }
      if (mounted) setState(() {});
    } catch (e) {
      await _showError(trf('Host-Fehler {fehler}', {'fehler': e}));
    }
  }

  Future<void> _initializeUpdates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final cachedVersion = prefs.getString('host_available_update_version');
    final cachedUrl = Uri.tryParse(
      prefs.getString('host_available_update_url') ?? '',
    );
    // Ein alter gespeicherter ZIP-Link wird mit den neuen Asset-Regeln geprüft.
    final refreshWindowsUrl =
        Platform.isWindows &&
        cachedVersion != null &&
        prefs.getInt('host_update_asset_format') != 1;
    if (!refreshWindowsUrl &&
        cachedVersion != null &&
        isNewerVersion(hostVersion, cachedVersion) &&
        cachedUrl?.scheme == 'https' &&
        cachedUrl!.host.isNotEmpty) {
      _availableUpdate = UpdateResult(
        UpdateStatus.available,
        version: cachedVersion,
        url: cachedUrl,
      );
    }
    _updates = UpdateCheck(
      installedVersion: hostVersion,
      platform: Platform.isMacOS ? UpdatePlatform.macos : UpdatePlatform.other,
      fetcher: Platform.isWindows ? fetchWindowsHostRelease : null,
      enabled: prefs.getBool('host_update_check') ?? true,
      lastCheck: refreshWindowsUrl
          ? null
          : DateTime.tryParse(prefs.getString('host_last_update_check') ?? ''),
      onState: () async {
        final last = _updates?.lastCheck;
        if (last != null) {
          await prefs.setString(
            'host_last_update_check',
            last.toIso8601String(),
          );
        }
      },
      onResult: (result) {
        if (!mounted) return;
        if (result.status == UpdateStatus.available) {
          _availableUpdate = result;
          unawaited(_showUpdateNotice(result));
        } else if (result.status == UpdateStatus.current) {
          _availableUpdate = null;
          unawaited(_clearUpdateNotice());
        }
      },
    );
    await _menu();
    if (_availableUpdate != null) await _showUpdateNotice(_availableUpdate!);
    _updates!.start();
  }

  Future<void> _clearUpdateNotice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('host_available_update_version');
      await prefs.remove('host_available_update_url');
      _updateNotice = null;
      await _menu();
      await trayManager.setToolTip('Remote for ADI-2 Host');
    } catch (_) {}
  }

  Future<void> _showUpdateNotice(UpdateResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('host_available_update_version', result.version!);
      await prefs.setString('host_available_update_url', result.url.toString());
      if (Platform.isWindows) await prefs.setInt('host_update_asset_format', 1);
      await _menu();
      if (_updateNotice != result.version) {
        _updateNotice = result.version;
        await trayManager.setToolTip(
          'Remote for ADI-2 Host · ${trf('Version {version} verfügbar', {'version': result.version})}',
        );
      }
    } catch (_) {
      // Update hints never open a window or interrupt the host.
    }
  }

  /// Prüft regelmäßig, ob und welcher ADI-2 angeschlossen ist.
  Future<void> _detect() async {
    if (_detecting || _exiting) return;
    _detecting = true;
    try {
      final found = await widget.midi.detect();
      if (!mounted || _exiting) return;
      if (!_detected || found != _adi2) {
        HostLog.write('Erkennung: ${found ?? 'kein ADI-2'}');
        _detected = true;
        _adi2 = found;
        unawaited(_menu());
      }
    } catch (_) {
      // A failed PnP read is not evidence of removal or a stale WinMM list.
      if (!Platform.isWindows) {
        if (!_detected || _adi2 != null) {
          _detected = true;
          _adi2 = null;
          if (mounted) unawaited(_menu());
        }
      }
    } finally {
      _detecting = false;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
    unawaited(_menu());
  }

  Future<void> _menu() {
    if (_exiting) return Future.value();
    _menuWork = _menuWork
        .catchError((Object _) {})
        .then(
          (_) => trayManager.setContextMenu(
            Menu(
              items: buildHostMenu(
                clientNames: server.connectedNames,
                rmeDevice: _adi2,
                status: server.status,
                error: _error,
                port: server.port,
                version: hostVersion,
                windows: Platform.isWindows,
                autostart: _automatic,
                updatesEnabled: _updates?.enabled ?? true,
                availableVersion: _availableUpdate?.version,
              ),
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
    try {
      await _menu();
    } catch (_) {
      // Auch bei ausgefallenem Tray bleibt das Fehlerfenster erreichbar.
    }
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
      case 'updates':
        final updates = _updates;
        if (updates == null) return;
        updates.enabled = !updates.enabled;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('host_update_check', updates.enabled);
        await _menu();
        if (updates.enabled) await updates.check();
      case 'download-update':
        final url = _availableUpdate?.url;
        if (url != null && !await openUpdate(url)) {
          try {
            await trayManager.setToolTip(
              tr('Download-Link konnte nicht geöffnet werden'),
            );
          } catch (_) {}
        }
      case 'quit':
        _exiting = true;
        _detectTimer?.cancel();
        await server.stop();
        if (widget.broadcast.isReady) await widget.broadcast.stop();
        await trayManager.destroy();
        await windowManager.destroy();
        exit(0);
    }
  }

  @override
  void dispose() {
    _updates?.stop();
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
              server.connectedNames.isEmpty
                  ? hostStatusText(server.status, server.connectedNames.length)
                  : '${hostStatusText(server.status, server.connectedNames.length)} · ${server.connectedNames.join(', ')}',
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
