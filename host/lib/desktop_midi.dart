import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';

import 'host_server.dart';

class DesktopMidi implements HostMidiPort {
  final MidiCommand command = MidiCommand();
  final _packets = StreamController<Uint8List>.broadcast();
  MidiDevice? _device;
  StreamSubscription<dynamic>? _rx, _setup;
  VoidCallback? onLost;
  @override
  Stream<Uint8List> get packets => _packets.stream;

  @override
  Future<String> open() async {
    if (_device != null) return _device!.name;
    command.configureTransportPolicy(
      const MidiTransportPolicy(
        excludedTransports: {
          MidiTransport.ble,
          MidiTransport.network,
          MidiTransport.virtual,
        },
      ),
    );
    final devices = await command.devices ?? [];
    final candidates = Adi2Controller.autoConnectCandidates(
      devices,
      Platform.isMacOS ? TargetPlatform.macOS : TargetPlatform.windows,
    );
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
    return withUsbName(target.name, await macUsbProductNames());
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
    if (device != null) command.disconnectDevice(device);
  }
}
