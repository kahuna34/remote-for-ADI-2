import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/supported_models.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';

import 'host_server.dart';

class DesktopMidi implements HostMidiPort {
  DesktopMidi({
    MidiCommand? command,
    TargetPlatform? platform,
    Future<List<String>> Function()? windowsNameQuery,
    Future<List<String>> Function()? macNameQuery,
  }) : command = command ?? MidiCommand(),
       _platform =
           platform ??
           (Platform.isMacOS ? TargetPlatform.macOS : TargetPlatform.windows),
       _windowsNameQuery = windowsNameQuery ?? windowsUsbProductNames,
       _macNameQuery = macNameQuery ?? macUsbProductNames;

  final MidiCommand command;
  final TargetPlatform _platform;
  final Future<List<String>> Function() _windowsNameQuery, _macNameQuery;
  String? _windowsCandidates;
  Future<List<String>>? _windowsNames;
  final _packets = StreamController<Uint8List>.broadcast();
  MidiDevice? _device;
  String? _deviceName;
  StreamSubscription<dynamic>? _rx, _setup;
  VoidCallback? onLost;
  @override
  Stream<Uint8List> get packets => _packets.stream;

  /// Erkennt einen angeschlossenen ADI-2, ohne den MIDI-Port zu öffnen, und
  /// liefert Modell und Seriennummer für die Anzeige im Menü.
  Future<String?> detect() async {
    final candidates = await _candidates();
    if (candidates.isEmpty) return null;
    return displayName(await _resolveDeviceName(candidates));
  }

  Future<List<MidiDevice>> _candidates() async {
    _configure();
    final candidates = Adi2Controller.autoConnectCandidates(
      await command.devices ?? [],
      _platform,
    );
    if (_platform == TargetPlatform.windows && candidates.isEmpty) {
      _windowsCandidates = null;
      _windowsNames = null;
    }
    return candidates;
  }

  Future<String> _resolveDeviceName(List<MidiDevice> candidates) async {
    final name = candidates.first.name;
    if (_platform != TargetPlatform.windows) {
      return withUsbName(name, await _macNameQuery());
    }
    // Reihenfolge und fremde MIDI-Ports lösen keine neue PnP-Abfrage aus.
    final ports = candidates.map((d) => jsonEncode([d.id, d.name])).toList()
      ..sort();
    final key = jsonEncode(ports);
    if (_windowsCandidates != key || _windowsNames == null) {
      _windowsCandidates = key;
      // Auch gleichzeitige open-/detect-Aufrufe teilen sich die Abfrage.
      _windowsNames = Future.sync(_windowsNameQuery)
          .catchError((Object _) => <String>[]);
    }
    final pending = _windowsNames!;
    final names = await pending;
    if (names.isEmpty && identical(_windowsNames, pending)) {
      // Leere oder fehlgeschlagene Abfragen beim nächsten Mal wiederholen.
      _windowsNames = null;
    }
    return withWindowsUsbName(name, names);
  }

  /// Anzeigename: Portzusatz entfernen, ADI-2 Pro EX an der Seriennummer
  /// erkennen (das Gerät meldet sich wie ein ADI-2 Pro).
  static String displayName(String name) {
    var n = name.replaceAll(RegExp(r'\s+(?:Midi\s+)?Port\s*\d+$'), '').trim();
    if (!n.contains('ADI-2')) n = 'ADI-2';
    final serial = RegExp(r'\((\d+)\)').firstMatch(n)?.group(1);
    if (n.startsWith('ADI-2 Pro (') && isProExSerial(serial)) {
      n = n.replaceFirst('ADI-2 Pro (', 'ADI-2 Pro EX (');
    }
    return n;
  }

  void _configure() => command.configureTransportPolicy(
    const MidiTransportPolicy(
      excludedTransports: {
        MidiTransport.ble,
        MidiTransport.network,
        MidiTransport.virtual,
      },
    ),
  );

  @override
  Future<String> open() async {
    if (_device != null) return _deviceName ?? _device!.name;
    final candidates = await _candidates();
    if (candidates.isEmpty) throw const HostUsbException('usb_missing');
    final target = candidates.first;
    try {
      await command.connectToDevice(target);
    } catch (_) {
      command.disconnectDevice(target);
      throw const HostUsbException('usb_busy');
    }
    _device = target;
    final assembler = SysexAssembler();
    _rx = command.onMidiPacketReceived?.listen(
      (packet) {
        if (packet.device.id != _device?.id) return;
        for (final bytes in assembler.add(packet.data)) {
          _packets.add(Uint8List.fromList(bytes));
        }
      },
      onError: (Object error) {
        onLost?.call();
      },
    );
    _setup = command.onMidiSetupChanged?.listen((_) async {
      final devices = await command.devices ?? [];
      if (_device != null && !devices.any((d) => d.id == _device!.id)) {
        await close();
        onLost?.call();
      }
    });
    _deviceName = await _resolveDeviceName(candidates);
    return _deviceName!;
  }

  // Der vom Bus gemeldete Gerätename kann Modell und Seriennummer enthalten.
  // Die physische USB-Instanzkennung dient zur Zuordnung; eine Hex-Kennung
  // von Windows ist keine Seriennummer.
  static const windowsPnpScript = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$devices = @(Get-PnpDevice -PresentOnly -Class MEDIA | Where-Object {
  $_.FriendlyName -match '^(RME\s+)?ADI-2'
} | ForEach-Object {
  $name = $_.FriendlyName
  $media = $_.InstanceId
  $current = $media
  $usb = $null
  $busNames = @((Get-PnpDeviceProperty -InstanceId $media -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction SilentlyContinue).Data)
  $serial = (Get-PnpDeviceProperty -InstanceId $current -KeyName 'DEVPKEY_Device_SerialNumber' -ErrorAction SilentlyContinue).Data
  $usbSerial = $null
  for ($depth = 0; $depth -lt 8 -and $current; $depth++) {
    if ($current -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[^\\]+$') {
      $usb = $current
      $usbSerial = (Get-PnpDeviceProperty -InstanceId $current -KeyName 'DEVPKEY_Device_SerialNumber' -ErrorAction SilentlyContinue).Data
      if ($current -ne $media) {
        $busNames += (Get-PnpDeviceProperty -InstanceId $current -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction SilentlyContinue).Data
      }
      break
    }
    $current = (Get-PnpDeviceProperty -InstanceId $current -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
  }
  [pscustomobject]@{name=$name; instanceId=$usb; serialNumber=$serial; usbSerialNumber=$usbSerial; busName=$busNames}
})
ConvertTo-Json -InputObject $devices -Compress
''';

  static const _pnpTimeout = Duration(seconds: 3);

  static Future<ProcessResult> _queryWindowsPnp() async {
    final process = await Process.start('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      windowsPnpScript,
    ]);
    try {
      final result = await Future.wait<Object>([
        process.exitCode,
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
      ]).timeout(_pnpTimeout);
      return ProcessResult(process.pid, result[0] as int, result[1], result[2]);
    } on TimeoutException {
      process.kill();
      rethrow;
    }
  }

  static Future<List<String>> windowsUsbProductNames({
    Future<ProcessResult> Function()? query,
    Duration timeout = _pnpTimeout,
  }) async {
    try {
      final result = await (query ?? _queryWindowsPnp)().timeout(timeout);
      if (result.exitCode != 0 || result.stdout is! String) return const [];
      return parseWindowsUsbProductNames(result.stdout as String);
    } catch (_) {
      return const [];
    }
  }

  /// Nur vollständige, widerspruchsfreie USB-Datensätze verwenden.
  /// Ein ADI-2 ohne lesbare Nummer macht auch andere Treffer mehrdeutig.
  static List<String> parseWindowsUsbProductNames(String output) {
    try {
      final decoded = jsonDecode(output.trim().replaceFirst('\uFEFF', ''));
      final rows = decoded is List ? decoded : [decoded];
      final names = <String, String>{};
      final modelPattern = RegExp(
        r'^(?:RME\s+)?(ADI-2(?:/4)?\s+(?:DAC|Pro)(?:\s+(?:FS|R|BE|SE|EX))*)$',
        caseSensitive: false,
      );
      final usbPattern = RegExp(
        r'^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\([^\\]+)$',
        caseSensitive: false,
      );
      final digits = RegExp(r'^\d+$');
      final busNamePattern = RegExp(r'^(.*?)\s+\((\d+)\)$');
      for (final row in rows) {
        if (row is! Map || row['name'] is! String) return const [];
        final model = modelPattern.firstMatch((row['name'] as String).trim());
        if (model == null) {
          if (RegExp(r'ADI-2', caseSensitive: false).hasMatch(row['name'])) {
            return const [];
          }
          continue;
        }
        final instance = row['instanceId'];
        final usb = instance is String ? usbPattern.firstMatch(instance) : null;
        if (usb == null) return const [];
        final serials = <String>{};
        if (digits.hasMatch(usb.group(1)!)) serials.add(usb.group(1)!);
        for (final property in [row['serialNumber'], row['usbSerialNumber']]) {
          if (property is String && digits.hasMatch(property.trim())) {
            serials.add(property.trim());
          }
        }
        final busNames = <String>{};
        final busName = row['busName'];
        final busValues = busName is List ? busName : [busName];
        for (final value in busValues) {
          if (value is! String) continue;
          final bus = busNamePattern.firstMatch(value.trim());
          if (bus == null) continue;
          final busModel = modelPattern.firstMatch(bus.group(1)!);
          if (busModel == null) continue;
          serials.add(bus.group(2)!);
          busNames.add('${busModel.group(1)} (${bus.group(2)})');
        }
        if (serials.length != 1) return const [];
        if (busNames.length > 1) return const [];
        final name = busNames.isNotEmpty
            ? busNames.single
            : '${model.group(1)} (${serials.single})';
        final key = (instance as String).toUpperCase();
        if (names.containsKey(key) && names[key] != name) return const [];
        names[key] = name;
      }
      return names.values.toList();
    } catch (_) {
      return const [];
    }
  }

  static String withWindowsUsbName(String portName, List<String> usbNames) {
    final model = RegExp(
      r'^(?:RME\s+)?(ADI-2(?:/4)?\s+(?:DAC|Pro))\b',
      caseSensitive: false,
    );
    final portModel = model
        .firstMatch(portName.trim())
        ?.group(1)
        ?.toLowerCase();
    if (portModel == null ||
        usbNames.length != 1 ||
        model.firstMatch(usbNames.single)?.group(1)?.toLowerCase() !=
            portModel) {
      return portName;
    }
    return withUsbName(portName, usbNames);
  }

  /// macOS meldet für den MIDI-Port nur „Port 1“. Der vollständige USB-Name
  /// enthält Modell und Seriennummer, die die App für Pro-EX-Erkennung,
  /// SD-LD-Prüfung und Wandleranzeige braucht.
  static Future<List<String>> macUsbProductNames() async {
    if (!Platform.isMacOS) return const [];
    try {
      final result = await Process.run('/usr/sbin/ioreg', [
        '-p',
        'IOUSB',
        '-w0',
        '-l',
      ]).timeout(const Duration(seconds: 3));
      return parseUsbProductNames(result.stdout as String);
    } catch (_) {
      return const [];
    }
  }

  static List<String> parseUsbProductNames(String ioreg) =>
      RegExp(r'"USB Product Name" = "(ADI-2[^"]*\(\d+\))"')
          .allMatches(ioreg)
          .map((m) => m.group(1)!)
          .toSet()
          .toList();

  /// Nur eindeutig ersetzen: genau ein ADI-2 am USB, Portname ohne Nummer.
  static String withUsbName(String portName, List<String> usbNames) {
    if (RegExp(r'\(\d+\)').hasMatch(portName)) return portName;
    return usbNames.length == 1 ? usbNames.single : portName;
  }

  @override
  void send(Uint8List data) {
    final device = _device;
    if (device != null) command.sendData(data, deviceId: device.id);
  }

  @override
  Future<void> close() async {
    await _rx?.cancel();
    _rx = null;
    await _setup?.cancel();
    _setup = null;
    final device = _device;
    _device = null;
    _deviceName = null;
    if (device != null) command.disconnectDevice(device);
  }
}
