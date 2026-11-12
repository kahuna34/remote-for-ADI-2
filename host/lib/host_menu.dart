// Die bestehende Desktop-API wird auch für die testbare Menübeschreibung genutzt.
// ignore_for_file: deprecated_member_use
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:tray_manager/legacy.dart';

/// Erstellt nur die Menübeschreibung; ruft keine Plattformfunktionen auf.
List<MenuItem> buildHostMenu({
  List<String> clientNames = const [],
  String? rmeDevice,
  String status = 'Bereit',
  String? error,
  int? port,
  required String version,
  required bool windows,
  required bool autostart,
  required bool updatesEnabled,
  String? availableVersion,
}) {
  final notices = <String>{
    if (error != null && error.isNotEmpty) error,
    if (status.isNotEmpty &&
        status != 'Bereit' &&
        status != 'Clients verbunden')
      tr(status),
    if (port != null && port != 0 && port != hostDefaultPort)
      trf('Port {standard} belegt; Host verwendet Port {port}', {
        'standard': hostDefaultPort,
        'port': port,
      }),
  };
  return [
    // Normale Einträge ohne Schlüssel/Aktion bleiben gut lesbar.
    MenuItem(
      label: trf('Client: {name}', {
        'name': clientNames.isEmpty ? '–' : clientNames.join(', '),
      }),
    ),
    MenuItem(label: trf('RME device: {name}', {'name': rmeDevice ?? '–'})),
    if (notices.isNotEmpty) MenuItem(label: notices.join(' · ')),
    MenuItem.separator(),
    MenuItem(key: 'pair', label: tr('Smartphone koppeln…')),
    MenuItem(key: 'devices', label: tr('Gekoppelte Geräte…')),
    MenuItem.checkbox(
      key: 'autostart',
      label: windows ? tr('Mit Windows starten') : tr('Bei Anmeldung starten'),
      checked: autostart,
    ),
    MenuItem.checkbox(
      key: 'updates',
      label: tr('Nach Updates suchen'),
      checked: updatesEnabled,
    ),
    MenuItem.separator(),
    if (availableVersion != null)
      MenuItem(
        key: 'download-update',
        label: trf('Update {version} laden…', {'version': availableVersion}),
      ),
    MenuItem(label: trf('Info: Version {version}', {'version': version})),
    MenuItem(key: 'quit', label: tr('Beenden')),
  ];
}

String hostStatusText(String status, int clientCount) =>
    status == 'Clients verbunden'
    ? clientCount == 1
          ? tr('1 Client verbunden')
          : trf('{n} Clients verbunden', {'n': clientCount})
    : tr(status);
