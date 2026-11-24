import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/usb_cc_mode.dart';
import 'package:adi2_remote/ui/analyzer_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux selects named ALSA ports and never guesses a generic Port 1', () {
    final adi = MidiDevice(
      '20:0',
      'ADI-2 DAC (1234567):ADI-2 DAC (1234567) MIDI 1 20:0',
      MidiDeviceType.serial,
      false,
    );
    final generic = MidiDevice('0:0', 'Port 1', MidiDeviceType.serial, false);
    expect(
      Adi2Controller.autoConnectCandidates([
        generic,
        adi,
      ], TargetPlatform.linux),
      [adi],
    );
    expect(
      Adi2Controller.autoConnectCandidates([generic], TargetPlatform.linux),
      isEmpty,
    );
  });
  test('Linux analyzer survives inactive windows and USB-CC mode stays unavailable', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(analyzerRunsIn(AppLifecycleState.inactive), isTrue);
    expect(analyzerRunsIn(AppLifecycleState.resumed), isTrue);
    expect(analyzerRunsIn(AppLifecycleState.hidden), isFalse);
    expect(await readUsbCcMode(), UsbCcMode.unknown);
  });
}
