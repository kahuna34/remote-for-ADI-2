import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/device/usb_cc_mode.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    Duration? awaitConnectionTimeout,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('adi2/usb');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final device = MidiDevice('usb', 'ADI-2 Pro', MidiDeviceType.unknown, false);

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Android maps channel values and unavailable access to unknown',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final value in ['stereo', 'multi', 'unknown', 'other', null]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'ccMode');
          return value;
        });
        expect(await readUsbCcMode(), switch (value) {
          'stereo' => UsbCcMode.stereo,
          'multi' => UsbCcMode.multi,
          _ => UsbCcMode.unknown,
        });
      }
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'no-access');
      });
      expect(await readUsbCcMode(), UsbCcMode.unknown);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await readUsbCcMode(), UsbCcMode.unknown);
    },
  );

  test('iOS does not query USB', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('USB queried on iOS'),
    );
    expect(await readUsbCcMode(), UsbCcMode.unknown);
  });

  test('Connect queries mode; offline and disconnect clear it', () async {
    var reads = 0;
    var next = UsbCcMode.stereo;
    final ctrl = Adi2Controller(
      midi: _Midi(),
      ccModeReader: () async {
        reads++;
        return next;
      },
    );
    addTearDown(ctrl.dispose);
    expect(ctrl.ccMode, UsbCcMode.unknown);
    await ctrl.connect(device);
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.ccMode, UsbCcMode.stereo);
    expect(reads, 1);
    next = UsbCcMode.multi;
    await ctrl.refreshCcMode();
    expect(ctrl.ccMode, UsbCcMode.multi);
    ctrl.disconnect();
    expect(ctrl.ccMode, UsbCcMode.unknown);
    await ctrl.startOffline(Adi2Variant.pro);
    await ctrl.refreshCcMode();
    expect(ctrl.ccMode, UsbCcMode.unknown);
    expect(reads, 2);
  });

  test(
    'Late responses cannot overwrite reset, newer query or disposed controller',
    () async {
      var response = Completer<UsbCcMode>();
      final ctrl = Adi2Controller(
        midi: _Midi(),
        ccModeReader: () => response.future,
      );
      ctrl.device = device;
      final old = ctrl.refreshCcMode();
      final first = response;
      response = Completer<UsbCcMode>();
      final latest = ctrl.refreshCcMode();
      response.complete(UsbCcMode.multi);
      await latest;
      first.complete(UsbCcMode.stereo);
      await old;
      expect(ctrl.ccMode, UsbCcMode.multi);

      response = Completer<UsbCcMode>();
      final pending = ctrl.refreshCcMode();
      ctrl.disconnect();
      response.complete(UsbCcMode.stereo);
      await pending;
      expect(ctrl.ccMode, UsbCcMode.unknown);

      ctrl.device = device;
      response = Completer<UsbCcMode>();
      final disposed = ctrl.refreshCcMode();
      ctrl.dispose();
      response.complete(UsbCcMode.stereo);
      await disposed;
      expect(ctrl.ccMode, UsbCcMode.unknown);
    },
  );

  test('Reader failure clears previously detected mode', () async {
    var fail = false;
    final ctrl = Adi2Controller(
      midi: _Midi(),
      ccModeReader: () async {
        if (fail) throw StateError('detached');
        return UsbCcMode.stereo;
      },
    );
    addTearDown(ctrl.dispose);
    ctrl.device = device;
    await ctrl.refreshCcMode();
    expect(ctrl.ccMode, UsbCcMode.stereo);
    fail = true;
    await ctrl.refreshCcMode();
    expect(ctrl.ccMode, UsbCcMode.unknown);
  });

  testWidgets('Opening the device page queries mode again', (tester) async {
    var reads = 0;
    final ctrl = Adi2Controller(
      midi: _Midi(),
      ccModeReader: () async {
        reads++;
        return reads == 1 ? UsbCcMode.stereo : UsbCcMode.multi;
      },
    );
    try {
      await ctrl.startOffline(Adi2Variant.pro);
      ctrl.state = ConnState.connected;
      ctrl.device = device;
      Future<void> openPage() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DevicePage(ctrl: ctrl)),
          ),
        );
        await tester.pumpAndSettle();
      }

      await openPage();
      expect(reads, 1);
      expect(ctrl.ccMode, UsbCcMode.stereo);
      await tester.pumpWidget(const SizedBox.shrink());
      await openPage();
      expect(reads, 2);
      expect(ctrl.ccMode, UsbCcMode.multi);
      expect(tester.takeException(), isNull);
    } finally {
      ctrl.dispose();
    }
  });
}
