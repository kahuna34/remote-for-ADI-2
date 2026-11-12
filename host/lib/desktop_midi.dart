import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/supported_models.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';

import 'host_server.dart';
import 'windows_pnp.dart';
import 'windows_midi.dart';
import 'host_log.dart';

class DesktopMidi implements HostMidiPort {
  DesktopMidi({
    MidiCommand? command,
    TargetPlatform? platform,
    Future<List<String>> Function()? windowsNameQuery,
    Future<List<String>> Function()? macNameQuery,
    MidiProcessStarter? processStarter,
    String? helperExecutable,
  }) : command = command ?? MidiCommand(),
       _windowsMidi = WindowsMidi(
         starter: processStarter,
         executable: helperExecutable,
       ),
       _platform =
           platform ??
           (Platform.isMacOS ? TargetPlatform.macOS : TargetPlatform.windows),
       _windowsNameQuery = windowsNameQuery ?? windowsPresentDeviceNames,
       _macNameQuery = macNameQuery ?? macUsbProductNames;

  final WindowsMidi _windowsMidi;
  MidiHelperSession? _windowsSession;
  Future<void>? _windowsClosing;
  Future<String>? _pendingOpen;
  int _generation = 0;
  bool windowsPnpUnreliable = false;
  bool _pnpSeen = false;

  final MidiCommand command;
  final TargetPlatform _platform;
  final Future<List<String>> Function() _windowsNameQuery, _macNameQuery;
  Future<List<String>>? _windowsNames;
  final _packets = StreamController<Uint8List>.broadcast();
  MidiDevice? _device;
  String? _deviceName;
  StreamSubscription<dynamic>? _rx, _setup;
  VoidCallback? onLost;
  bool _opening = false;
  bool get portInUse => _opening || _device != null || _windowsSession != null;
  bool? windowsPnpPresent;
  @override
  Stream<Uint8List> get packets => _packets.stream;

  /// Erkennt einen angeschlossenen ADI-2, ohne den MIDI-Port zu öffnen, und
  /// liefert Modell und Seriennummer für die Anzeige im Menü.
  Future<String?> detect() async {
    if (_platform == TargetPlatform.windows) {
      windowsPnpPresent = null;
      final names = windowsPnpUnreliable
          ? const <String>[]
          : await _queryWindowsNames();
      if (!windowsPnpUnreliable) windowsPnpPresent = names.isNotEmpty;
      if (names.isNotEmpty) {
        windowsPnpUnreliable = false;
        return displayName(names.first);
      }
      // On systems whose PnP names never expose ADI-2, a fresh helper can
      // establish the fallback at any time, including after a later hotplug.
      if (windowsPnpUnreliable || !_pnpSeen) {
        final ports = await _windowsMidi.list();
        final candidates = ports.candidates;
        if (candidates.isNotEmpty) {
          windowsPnpUnreliable = true;
          return displayName(candidates.first);
        }
      }
      if (_windowsSession != null) {
        await close();
        onLost?.call();
      }
      return null;
    }
    final candidates = await _candidates();
    if (candidates.isEmpty) return null;
    return displayName(await _resolveDeviceName(candidates));
  }

  Future<List<MidiDevice>> _candidates() async {
    _configure();
    return Adi2Controller.autoConnectCandidates(
      await command.devices ?? [],
      _platform,
    );
  }

  Future<List<String>> _queryWindowsNames() {
    // Only concurrent callers share work; the next poll always reads PnP.
    return _windowsNames ??= Future.sync(_windowsNameQuery)
        .then((names) {
          if (names.isNotEmpty) _pnpSeen = true;
          return names;
        })
        .whenComplete(() {
          _windowsNames = null;
        });
  }

  Future<String> _resolveDeviceName(List<MidiDevice> candidates) async {
    final name = candidates.first.name;
    if (_platform != TargetPlatform.windows) {
      return withUsbName(name, await _macNameQuery());
    }
    return withWindowsUsbName(name, await _queryWindowsNames());
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
  Future<String> open() {
    if (_pendingOpen != null) return _pendingOpen!;
    if (_windowsSession != null || _device != null) {
      return Future.value(_deviceName ?? _device!.name);
    }
    _opening = true;
    final generation = _generation;
    return _pendingOpen = (() async {
      try {
        return _platform == TargetPlatform.windows
            ? await _openWindows(generation)
            : await _openDevice();
      } finally {
        _opening = false;
        _pendingOpen = null;
      }
    })();
  }

  Future<String> _openWindows(int generation) async {
    MidiHelperSession? session;
    try {
      await _windowsClosing;
      // PnP supplies display metadata; only the fresh helper decides which
      // ports can actually open, including on systems with unusable PnP.
      var names = const <String>[];
      try {
        names = await _queryWindowsNames();
      } catch (error) {
        HostLog.write('MIDI USB-Name nicht verfügbar: $error');
      }
      final candidates = (await _windowsMidi.list()).candidates;
      if (candidates.isEmpty || generation != _generation) {
        throw const HostUsbException('usb_missing');
      }
      final target = candidates.first;
      final process = await _windowsMidi.start(['open', target]);
      session = MidiHelperSession(
        process,
        onPacket: (bytes) {
          if (generation == _generation) _packets.add(bytes);
        },
        onLost: () {
          if (generation != _generation) return;
          _windowsSession = null;
          _deviceName = null;
          _windowsClosing = session!.close();
          onLost?.call();
        },
      );
      if (generation != _generation) {
        // Attach the error handler before closing an unfinished handshake.
        unawaited(session.opened.catchError((Object _) => ''));
        throw const HostUsbException('usb_missing');
      }
      _windowsSession = session;
      final portName = await session.opened;
      if (generation != _generation || _windowsSession != session) {
        throw const HostUsbException('usb_missing');
      }
      _deviceName = withWindowsUsbName(portName, names);
      return _deviceName!;
    } catch (error) {
      HostLog.write('MIDI-Hilfsprozess Öffnen fehlgeschlagen: $error');
      if (_windowsSession == session) {
        _windowsSession = null;
        _deviceName = null;
      }
      await session?.close();
      if (error is HostUsbException) rethrow;
      throw HostUsbException(
        error is MidiHelperException && error.code == 'busy'
            ? 'usb_busy'
            : 'usb_missing',
      );
    }
  }

  Future<String> _openDevice() async {
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

  static const _pnpTimeout = Duration(seconds: 10);

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

  /// Empty native results are authoritative. PowerShell runs only when the
  /// native API fails, never to confirm absence or to refresh a name cache.
  static Future<List<String>> windowsPresentDeviceNames({
    FutureOr<List<String>> Function()? nativeQuery,
    Future<List<String>> Function()? fallbackQuery,
  }) async {
    try {
      return await (nativeQuery ?? WindowsPnp.productNames)();
    } catch (_) {
      return await (fallbackQuery ??
          () => windowsUsbProductNames(presence: true))();
    }
  }

  static List<String> parseWindowsPnpPresence(String output) {
    final decoded = jsonDecode(output.trim().replaceFirst('\uFEFF', ''));
    final rows = decoded is List ? decoded : [decoded];
    final names = <String>[];
    for (final row in rows) {
      if (row is! Map || row['name'] is! String) {
        throw const FormatException('Invalid PnP device');
      }
      final friendly = row['name'] as String;
      if (!WindowsPnp.isAdi2(friendly)) continue;
      final value = row['busName'];
      final buses = value is List ? value : [value];
      final bus = buses
          .whereType<String>()
          .where(WindowsPnp.isAdi2)
          .firstOrNull;
      names.add(WindowsPnp.deviceName(friendly, bus));
    }
    return names;
  }

  static Future<List<String>> windowsUsbProductNames({
    Future<ProcessResult> Function()? query,
    Duration timeout = _pnpTimeout,
    bool presence = false,
  }) async {
    try {
      final result = await (query ?? _queryWindowsPnp)().timeout(timeout);
      if (result.exitCode != 0 || result.stdout is! String) {
        if (presence) throw StateError('PnP query failed');
        return const [];
      }
      return presence
          ? parseWindowsPnpPresence(result.stdout as String)
          : parseWindowsUsbProductNames(result.stdout as String);
    } catch (_) {
      if (presence) rethrow;
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
    if (_platform == TargetPlatform.windows) {
      _windowsSession?.send(data);
      return;
    }
    final device = _device;
    if (device != null) command.sendData(data, deviceId: device.id);
  }

  @override
  Future<void> close() async {
    _generation++;
    final session = _windowsSession;
    _windowsSession = null;
    _deviceName = null;
    final closing = _windowsClosing;
    _windowsClosing = null;
    await session?.close();
    await closing;
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
