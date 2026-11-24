import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../device/adi2_controller.dart';
import '../host/host_client.dart';
import '../host/host_errors.dart';
import '../host/host_discovery.dart';
import '../host/host_protocol.dart';
import '../l10n/l10n.dart';
import 'theme.dart';

class HostConnectPage extends StatefulWidget {
  const HostConnectPage({super.key, required this.ctrl});
  final Adi2Controller ctrl;
  @override
  State<HostConnectPage> createState() => _HostConnectPageState();
}

class _HostConnectPageState extends State<HostConnectPage> {
  HostDiscovery get _discovery => widget.ctrl.hostDiscovery;
  final _address = TextEditingController();
  final _port = TextEditingController(text: '$hostDefaultPort');
  final _code = TextEditingController();
  final _name = TextEditingController();
  HostEndpoint? _selected;
  bool _busy = false;
  int _operation = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.text = widget.ctrl.canSelectDesktopHost
        ? Platform.localHostname.substring(
            0,
            Platform.localHostname.length.clamp(0, 100),
          )
        : tr('Mein Smartphone');
  }

  @override
  void dispose() {
    for (final field in [_address, _port, _code, _name]) {
      field.dispose();
    }
    super.dispose();
  }

  void _select(HostEndpoint host, {String? code}) {
    setState(() {
      _selected = host;
      _address.text = host.address;
      _port.text = '${host.port}';
      if (code != null) _code.text = code;
    });
  }

  Future<void> _scan() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _HostScanner()),
    );
    if (raw == null || !mounted) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['type'] != 'adi2-pair-v1') throw const FormatException();
      _select(HostEndpoint.fromJson(data), code: data['code'] as String);
    } catch (_) {
      setState(() => _error = tr('Ungültiger Host-QR-Code'));
    }
  }

  Future<void> _pair() async {
    final operation = ++_operation;
    final port = int.tryParse(_port.text);
    if (_address.text.trim().isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^\d{6}$').hasMatch(_code.text.trim()) ||
        _name.text.trim().isEmpty) {
      setState(
        () => _error = widget.ctrl.canSelectDesktopHost
            ? tr('Adresse, Port, Rechnername und sechsstelligen Code eingeben')
            : tr(
                'Adresse, Port, Smartphone-Name und sechsstelligen Code eingeben',
              ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selected = _selected;
      final host = HostEndpoint(
        id: selected?.address == _address.text.trim() ? selected!.id : '',
        name: selected?.name ?? _address.text.trim(),
        address: _address.text.trim(),
        port: port,
      );
      final credentials = await widget.ctrl.pairHost(
        host,
        _code.text.trim(),
        _name.text.trim(),
      );
      if (widget.ctrl.canSelectDesktopHost &&
          (!mounted || operation != _operation)) {
        return;
      }
      await widget.ctrl.savePairedHost(credentials);
      if (widget.ctrl.canSelectDesktopHost &&
          (!mounted || operation != _operation)) {
        return;
      }
      await widget.ctrl.connectHost(credentials);
      if (mounted) {
        if (widget.ctrl.host.connected) {
          Navigator.pop(context);
        } else {
          setState(() => _error = widget.ctrl.error);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = hostErrorText(error.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Aktive Verbindung: verbunden (oder gerade neu verbindend) über diesen Host.
  bool _isActive(String id) =>
      id.isNotEmpty &&
      widget.ctrl.viaHost &&
      !widget.ctrl.usesLocalHost &&
      widget.ctrl.hostId == id;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('Über Host verbinden'))),
    body: ListenableBuilder(
      listenable: Listenable.merge([_discovery, widget.ctrl]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            tr(
              'Host am Computer starten und dort „Client koppeln…“ öffnen.',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr('Stufe 1 überträgt im lokalen Netzwerk ohne Verschlüsselung.'),
          ),
          const SizedBox(height: 12),
          _ActiveHostBanner(ctrl: widget.ctrl),
          if (widget.ctrl.canSelectDesktopHost)
            _HostChoice(
              active: widget.ctrl.usesLocalHost,
              child: ListTile(
                key: const ValueKey('host-select-local'),
                leading: const Icon(Icons.desktop_windows),
                title: Text(tr('Dieser Rechner')),
                subtitle: Text(widget.ctrl.desktopSelection!.local.host.name),
                trailing: widget.ctrl.usesLocalHost
                    ? const _ActiveMark()
                    : null,
                onTap: () async {
                  ++_operation;
                  try {
                    await widget.ctrl.connectLocalHost();
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    if (mounted) {
                      setState(() => _error = hostErrorText(error.toString()));
                    }
                  }
                },
              ),
            ),
          for (final host in widget.ctrl.discoveredHosts)
            _HostChoice(
              active: _isActive(host.id),
              child: ListTile(
                leading: const Icon(Icons.computer),
                title: Text(host.name),
                subtitle: Text('${host.address}:${host.port}'),
                trailing: _isActive(host.id) ? const _ActiveMark() : null,
                onTap: _busy ? null : () => _select(host),
              ),
            ),
          for (final saved in widget.ctrl.pairedHosts)
            _HostChoice(
              active: _isActive(saved.host.id),
              child: ListTile(
                leading: const Icon(Icons.link),
                title: Text(saved.host.name),
                subtitle: Text(
                  _isActive(saved.host.id)
                      ? tr('Gekoppelt · aktiv verbunden')
                      : tr('Gekoppelt'),
                ),
                onTap: _busy
                    ? null
                    : () async {
                        final operation = ++_operation;
                        final resolved = _discovery.hosts[saved.host.id];
                        final credentials = resolved == null
                            ? saved
                            : HostCredentials(
                                resolved,
                                saved.deviceId,
                                saved.key,
                              );
                        setState(() {
                          _busy = true;
                          _error = null;
                        });
                        try {
                          await widget.ctrl.savePairedHost(credentials);
                          if (widget.ctrl.canSelectDesktopHost &&
                              (!mounted || operation != _operation)) {
                            return;
                          }
                          await widget.ctrl.connectHost(credentials);
                          if (context.mounted && widget.ctrl.host.connected) {
                            Navigator.pop(context);
                          }
                        } catch (error) {
                          if (mounted) {
                            setState(
                              () => _error = hostErrorText(error.toString()),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                trailing: IconButton(
                  tooltip: tr('Kopplung entfernen'),
                  icon: const Icon(Icons.link_off),
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            await widget.ctrl.forgetHost(saved.host.id);
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _error = tr(
                                  'Kopplung konnte nicht gespeichert werden',
                                ),
                              );
                            }
                          }
                        },
                ),
              ),
            ),
          if (!widget.ctrl.canSelectDesktopHost) ...[
            OutlinedButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(tr('QR-Code scannen')),
            ),
            Text(
              tr(
                'Die Kamera wird zum Scannen des Kopplungs-QR-Codes verwendet.',
              ),
            ),
          ],
          TextField(
            controller: _address,
            decoration: InputDecoration(labelText: tr('Manuelle Host-Adresse')),
            keyboardType: TextInputType.url,
          ),
          TextField(
            controller: _port,
            decoration: InputDecoration(labelText: tr('Port')),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: _name,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: widget.ctrl.canSelectDesktopHost
                  ? tr('Rechnername')
                  : tr('Smartphone-Name'),
            ),
          ),
          TextField(
            controller: _code,
            maxLength: 6,
            decoration: InputDecoration(labelText: tr('Kopplungscode')),
            keyboardType: TextInputType.number,
          ),
          FilledButton(
            onPressed: _busy ? null : _pair,
            child: Text(tr('Koppeln und verbinden')),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null || widget.ctrl.error != null)
            Text(
              _error ?? widget.ctrl.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}

class _HostScanner extends StatefulWidget {
  const _HostScanner();
  @override
  State<_HostScanner> createState() => _HostScannerState();
}

class _HostScannerState extends State<_HostScanner> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('QR-Code scannen'))),
    body: MobileScanner(
      onDetect: (capture) {
        final value = capture.barcodes.firstOrNull?.rawValue;
        if (!_done && value != null) {
          _done = true;
          Navigator.pop(context, value);
        }
      },
    ),
  );
}

/// Hebt die gerade gewählte Host-Verbindung deutlich hervor.
class _HostChoice extends StatelessWidget {
  const _HostChoice({required this.active, required this.child});
  final bool active;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    // Material statt Container: ListTile braucht ein Material für Hintergrund
    // und Tipp-Effekt.
    child: Material(
      color: active ? Palette.surf2 : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: active ? Palette.amber : Colors.transparent,
          width: 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

class _ActiveMark extends StatelessWidget {
  const _ActiveMark();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(tr('Aktiv'), style: const TextStyle(color: Palette.green)),
      const SizedBox(width: 6),
      const Icon(Icons.check_circle, color: Palette.green),
    ],
  );
}

/// Oben auf der Seite: mit welchem Host die App gerade verbunden ist.
class _ActiveHostBanner extends StatelessWidget {
  const _ActiveHostBanner({required this.ctrl});
  final Adi2Controller ctrl;
  @override
  Widget build(BuildContext context) {
    final local = ctrl.canSelectDesktopHost && ctrl.usesLocalHost;
    final connected = ctrl.viaHost && ctrl.host.connected;
    final name = local
        ? tr('Dieser Rechner')
        : ctrl.viaHost
        ? (ctrl.host.hostName ?? '')
        : '';
    if (!local && !ctrl.viaHost) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('host-active-banner'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Palette.surf2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.amber, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 12,
            color: connected || local ? Palette.green : Palette.amber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              connected || local
                  ? trf('Verbunden mit {name}', {'name': name})
                  : trf('Verbinde mit {name} …', {'name': name}),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
