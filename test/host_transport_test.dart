import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/host/host_discovery.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Midi implements MidiCommand {
  List<MidiDevice> available = [];
  final connected = <MidiDevice>[];
  @override
  Future<List<MidiDevice>> get devices async => available;
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    Duration? awaitConnectionTimeout,
  }) async {
    connected.add(device);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Host extends HostClient {
  bool online = false;
  final sent = <Uint8List>[];
  @override
  bool get connected => online;
  @override
  Future<void> connect(HostCredentials value) async {
    credentials = value;
    online = true;
    deviceName = 'ADI-2 Pro (56010042)';
    notifyListeners();
  }

  @override
  void disconnect() {
    online = false;
  }

  @override
  void sendMidi(Uint8List bytes) {
    if (online) sent.add(bytes);
  }

  void drop() {
    online = false;
    notifyListeners();
  }
}

class _Discovery extends HostDiscovery {
  @override
  Future<void> start() async {}
}

class _Controller extends Adi2Controller {
  _Controller(_Host host, _Midi midi) : super(host: host, midi: midi);
  @override
  bool get hostAvailable => true;
  @override
  HostDiscovery get hostDiscovery => _testDiscovery;
  final _testDiscovery = _Discovery();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Host host;
  late _Midi midi;
  late _Controller controller;
  late HostCredentials credentials;
  var disposed = false;
  setUp(() {
    disposed = false;
    SharedPreferences.setMockInitialValues({});
    host = _Host();
    midi = _Midi();
    controller = _Controller(host, midi);
    credentials = HostCredentials(
      const HostEndpoint(
        id: 'host',
        name: 'Computer',
        address: '127.0.0.1',
        port: 47321,
      ),
      'phone',
      randomToken(),
    );
  });
  tearDown(() {
    if (!disposed) controller.dispose();
  });

  test(
    'Abriss verwirft Rampe und Zustand, Wiederverbindung liest neu',
    () async {
      await controller.start();
      await controller.connectHost(credentials);
      expect(
        host.sent.any((p) => listEquals(p, buildRequestAll(0x72))),
        isTrue,
      );
      expect(controller.deviceSerial, '56010042');
      final reply = buildSetParams(0x72, [
        const Adi2Param(3, OutIdx.volume, -500),
      ]).single;
      reply[5] = Adi2Cmd.paramsToRemote;
      host.packets.add(reply);
      expect(controller.value(3, OutIdx.volume), -500);
      controller.setVolume(3, 0);
      expect(controller.volGuard.isIdle, isFalse);
      host.drop();
      expect(controller.volGuard.isIdle, isTrue);
      expect(controller.value(3, OutIdx.volume), isNull);
      final before = host.sent.length;
      controller.setVolume(3, 0);
      await controller.connectHost(credentials);
      expect(
        host.sent.skip(before).every((p) => p[5] == Adi2Cmd.request),
        isTrue,
      );
      expect(controller.value(3, OutIdx.volume), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 650));
    },
  );

  test('USB übernimmt eine bestehende Host-Sitzung', () async {
    await controller.start();
    await controller.connectHost(credentials);
    final usb = MidiDevice(
      'usb',
      'ADI-2 DAC (12345678)',
      MidiDeviceType.serial,
      false,
    );
    midi.available = [usb];
    // Derselbe Weg wie das MIDI-Setup-Ereignis bzw. der automatische Retry.
    controller.setHostForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.viaHost, isFalse);
    expect(host.connected, isFalse);
    expect(midi.connected, [usb]);
  });

  testWidgets(
    'HOST ersetzt OFFLINE und bleibt in der Kopfzeile kollisionsfrei',
    (tester) async {
      await controller.start();
      await controller.connectHost(credentials);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 328,
              child: HomeHeaderRow(
                title: const Text('ADI-2'),
                badge: connectionBadge(controller),
                actions: Row(
                  key: const Key('actions'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const HostBadge(),
                    const SizedBox(width: 164, height: 44),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('host-badge')), findsOneWidget);
      expect(find.byKey(const ValueKey('offline-badge')), findsNothing);
      final badge = tester.getRect(find.byKey(const ValueKey('host-badge')));
      expect(connectionBadge(controller), isNull);
      expect(
        badge.left,
        greaterThanOrEqualTo(tester.getRect(find.text('ADI-2')).right),
      );
      expect(find.text('HOST'), findsOneWidget);
      expect(find.text('Computer'), findsNothing);
      expect(badge.height, 34);
      expect(tester.takeException(), isNull);
      controller.dispose();
      disposed = true;
    },
  );
}
