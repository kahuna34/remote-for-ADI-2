import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../device/adi2_controller.dart';
import '../host/host_client.dart';
import '../host/host_errors.dart';
import '../host/host_discovery.dart';
import '../host/host_protocol.dart';
import '../l10n/l10n.dart';

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
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.text = tr('Mein Smartphone');
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
    final port = int.tryParse(_port.text);
    if (_address.text.trim().isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^\d{6}$').hasMatch(_code.text.trim()) ||
        _name.text.trim().isEmpty) {
      setState(
        () => _error = tr(
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
      final credentials = await HostClient.pair(
        host,
        _code.text.trim(),
        _name.text.trim(),
      );
      await widget.ctrl.savePairedHost(credentials);
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
              'Host am Computer starten und dort „Smartphone koppeln…“ öffnen.',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr('Stufe 1 überträgt im lokalen Netzwerk ohne Verschlüsselung.'),
          ),
          for (final host in _discovery.hosts.values)
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(host.name),
              subtitle: Text('${host.address}:${host.port}'),
              onTap: _busy ? null : () => _select(host),
            ),
          for (final saved in widget.ctrl.pairedHosts)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(saved.host.name),
              subtitle: Text(tr('Gekoppelt')),
              onTap: _busy
                  ? null
                  : () async {
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
          OutlinedButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(tr('QR-Code scannen')),
          ),
          Text(
            tr('Die Kamera wird zum Scannen des Kopplungs-QR-Codes verwendet.'),
          ),
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
            decoration: InputDecoration(labelText: tr('Smartphone-Name')),
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
