import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';

MidiDevice _device(String name) =>
    MidiDevice(name, name, MidiDeviceType.serial, false);

void main() {
  List<String> names(List<MidiDevice> devices, TargetPlatform platform) =>
      Adi2Controller.autoConnectCandidates(
        devices,
        platform,
      ).map((d) => d.name).toList();

  test('ADI-2 im Namen wird auf allen Plattformen erkannt', () {
    final devices = [_device('Keyboard'), _device('ADI-2 DAC (52000000)')];
    for (final platform in TargetPlatform.values) {
      expect(names(devices, platform), ['ADI-2 DAC (52000000)']);
    }
  });

  test('Einzelner Port 1 gilt nur auf Apple-Geräten', () {
    final devices = [_device('Port 1')];
    expect(names(devices, TargetPlatform.macOS), ['Port 1']);
    expect(names(devices, TargetPlatform.iOS), ['Port 1']);
    expect(names(devices, TargetPlatform.android), isEmpty);
  });

  test('Mehrere oder fremde Geräte werden nicht automatisch verbunden', () {
    expect(
      names([_device('Port 1'), _device('Port 2')], TargetPlatform.macOS),
      isEmpty,
    );
    expect(names([_device('Keyboard')], TargetPlatform.iOS), isEmpty);
    expect(names([], TargetPlatform.iOS), isEmpty);
  });
}
