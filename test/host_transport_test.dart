import 'dart:async';

import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/eq/eq_model.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_errors.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/host/host_discovery.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/outputs_page.dart';
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
  @override
  bool awaitingSilenceTimeout = false;
  bool failConnect = false;
  String nextDeviceName = 'ADI-2 Pro (56010042)';
  final sent = <Uint8List>[];
  void Function(Uint8List)? onSend;
  @override
  bool get connected => online;
  @override
  Future<void> connect(HostCredentials value) async {
    credentials = value;
    if (failConnect) throw StateError('Host antwortet nicht');
    error = null;
    online = true;
    deviceName = nextDeviceName;
    notifyListeners();
  }

  @override
  void disconnect() {
    online = false;
    super.disconnect();
  }

  @override
  void sendMidi(Uint8List bytes) {
    if (online) {
      sent.add(bytes);
      onSend?.call(bytes);
    }
  }

  void drop([String why = 'Host antwortet nicht']) {
    error = why;
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
    'Abriss erhält Anzeige, verwirft Rampe und Eingaben, Abgleich liest neu',
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
      expect(controller.value(3, OutIdx.volume), -500);
      expect(controller.model, Adi2Model.pro);
      expect(controller.hostReconnecting, isTrue);
      expect(controller.isConnected, isFalse);
      final before = host.sent.length;
      controller.setVolume(3, 0);
      controller.set(3, OutIdx.polarity, 2);
      controller.setEq(4, 4, 10);
      controller.loadSetup(1);
      expect(controller.volGuard.isIdle, isTrue);
      expect(host.sent.length, before);
      await controller.connectHost(credentials);
      expect(
        host.sent.skip(before).every((p) => p[5] == Adi2Cmd.request),
        isTrue,
      );
      expect(controller.value(3, OutIdx.volume), -500);
      expect(controller.isConnected, isFalse); // Auth allein genügt nicht.
      final fresh = buildSetParams(0x72, [
        const Adi2Param(3, OutIdx.volume, -650),
      ]).single..[5] = Adi2Cmd.paramsToRemote;
      host.packets.add(fresh);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.hostReconnecting, isFalse);
      expect(controller.isConnected, isTrue);
      expect(controller.value(3, OutIdx.volume), -650);
      expect(controller.volGuard.isIdle, isTrue);
      expect(
        host.sent.skip(before).every((p) => p[5] == Adi2Cmd.request),
        isTrue,
      );
      controller.set(3, OutIdx.polarity, 1);
      expect(host.sent.last[5], Adi2Cmd.paramsToDevice);
      await Future<void>.delayed(const Duration(milliseconds: 650));
    },
  );

  test(
    'MIDI-Watchdog leert vor der Transport-Stille-Erkennung keine Anzeige',
    () async {
      await controller.start();
      await controller.connectHost(credentials);
      host.packets.add(
        buildSetParams(0x72, [const Adi2Param(3, OutIdx.volume, -500)]).single
          ..[5] = Adi2Cmd.paramsToRemote,
      );
      host.awaitingSilenceTimeout = true;
      await Future<void>.delayed(const Duration(milliseconds: 6200));
      expect(controller.state, ConnState.connected);
      expect(controller.value(3, OutIdx.volume), -500);
      host.drop();
      expect(controller.hostReconnecting, isTrue);
      expect(controller.value(3, OutIdx.volume), -500);
    },
  );

  void receive({int id = 0x72, int volume = -500, int? polarity}) {
    host.packets.add(
      buildSetParams(id, [
        Adi2Param(3, OutIdx.volume, volume),
        if (polarity != null) Adi2Param(3, OutIdx.polarity, polarity),
      ]).single..[5] = Adi2Cmd.paramsToRemote,
    );
  }

  Future<void> cleanup(WidgetTester tester) async {
    controller.dispose();
    disposed = true;
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Ohne Neuverbindung endet die Anzeige nach genau zehn Sekunden', (
    tester,
  ) async {
    await controller.start();
    await controller.connectHost(credentials);
    receive();
    controller.selectedOutput = 6;
    controller.names[1] = 'Studio';
    host.failConnect = true;
    host.drop();
    await tester.pump(const Duration(milliseconds: 9999));
    expect(controller.hostReconnecting, isTrue);
    expect(controller.model, Adi2Model.pro);
    expect(controller.selectedOutput, 6);
    expect(controller.names[1], 'Studio');
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.state, ConnState.searching);
    expect(controller.model, isNull);
    expect(controller.value(3, OutIdx.volume), isNull);
    expect(host.reconnecting, isFalse);
    await cleanup(tester);
  });

  testWidgets(
    'Unvollständiger Abgleich sperrt trotz Authentifizierung bis zum Timeout',
    (tester) async {
      await controller.start();
      await controller.connectHost(credentials);
      receive(polarity: 0);
      host.drop();
      await controller.connectHost(credentials);
      receive(volume: -700); // Polarity wurde noch nicht neu bestätigt.
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.hostReconnecting, isTrue);
      final before = host.sent.length;
      controller.set(3, OutIdx.polarity, 2);
      controller.setMany([const Adi2Param(3, OutIdx.volume, 0)]);
      expect(host.sent, hasLength(before));
      await tester.pump(const Duration(milliseconds: 9500));
      expect(controller.model, isNull);
      expect(controller.hostReconnecting, isFalse);
      await cleanup(tester);
    },
  );

  for (final action in [
    'Trennen',
    'Pause',
    'Offline',
    'Hintergrund',
    'Kopplung entfernen',
    'USB',
  ]) {
    testWidgets('$action beendet die Überbrückung sofort', (tester) async {
      await controller.start();
      await controller.connectHost(credentials);
      receive();
      host.drop();
      switch (action) {
        case 'Trennen':
          controller.disconnect();
        case 'Pause':
          await controller.pauseHost();
        case 'Offline':
          await controller.startOffline(Adi2Variant.dac);
        case 'Hintergrund':
          controller.setHostForeground(false);
        case 'Kopplung entfernen':
          await controller.forgetHost(credentials.host.id);
        case 'USB':
          await controller.connect(
            MidiDevice('usb', 'ADI-2 DAC', MidiDeviceType.serial, false),
          );
      }
      expect(controller.hostReconnecting, isFalse);
      expect(controller.viaHost, isFalse);
      expect(controller.volGuard.isIdle, isTrue);
      expect(controller.model, action == 'Offline' ? Adi2Model.dac : isNull);
      await cleanup(tester);
    });
  }

  testWidgets(
    'Frischer Status und alle Parameter sind vor Freigabe erforderlich',
    (tester) async {
      await controller.start();
      await controller.connectHost(credentials);
      receive(polarity: 0);
      void status() => host.packets.add(
        Uint8List.fromList([
          0xf0,
          ...rmeVendor,
          0x72,
          Adi2Cmd.status,
          ...List.filled(24, 0),
          0xf7,
        ]),
      );
      status();
      controller.selectedOutput = 3;
      host.drop();
      await controller.connectHost(credentials);
      receive(volume: -700, polarity: 2);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.hostReconnecting, isTrue);
      status();
      await tester.pump(const Duration(milliseconds: 150));
      expect(controller.hostReconnecting, isFalse);
      expect(controller.value(3, OutIdx.volume), -700);
      expect(controller.value(3, OutIdx.polarity), 2);
      expect(controller.selectedOutput, 3);
      await cleanup(tester);
    },
  );

  testWidgets(
    'Gedrücktgehaltene Lautstärketaste läuft nach dem Abgleich nicht weiter',
    (tester) async {
      await controller.start();
      await controller.connectHost(credentials);
      receive();
      controller.selectedOutput = 3;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OutputsPage(ctrl: controller)),
        ),
      );
      final plus = find.descendant(
        of: find.byKey(const ValueKey('output-volume-buttons')),
        matching: find.byIcon(Icons.add),
      );
      final gesture = await tester.startGesture(tester.getCenter(plus));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(host.sent.any((p) => p[5] == Adi2Cmd.paramsToDevice), isTrue);
      host.drop();
      await controller.connectHost(credentials);
      receive(volume: -700);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.isConnected, isTrue);
      final writes = host.sent
          .where((p) => p[5] == Adi2Cmd.paramsToDevice)
          .length;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.volGuard.isIdle, isTrue);
      expect(
        host.sent.where((p) => p[5] == Adi2Cmd.paramsToDevice),
        hasLength(writes),
      );
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
      await cleanup(tester);
    },
  );

  testWidgets('Neuer Abriss verlängert die ursprüngliche Frist nicht', (
    tester,
  ) async {
    await controller.start();
    await controller.connectHost(credentials);
    receive();
    host.drop();
    await tester.pump(const Duration(seconds: 6));
    await controller.connectHost(credentials);
    host.drop();
    await tester.pump(const Duration(seconds: 4));
    expect(controller.model, isNull);
    expect(controller.hostReconnecting, isFalse);
    await cleanup(tester);
  });

  testWidgets('Anderes Gerät oder Modell löscht die alte Anzeige', (
    tester,
  ) async {
    await controller.start();
    await controller.connectHost(credentials);
    receive();
    host.drop();
    host.nextDeviceName = 'ADI-2 DAC (12345678)';
    await controller.connectHost(credentials);
    expect(controller.hostReconnecting, isFalse);
    expect(controller.model, isNull);
    expect(controller.state, ConnState.waitingForDevice);
    receive(id: 0x71);
    expect(controller.model, Adi2Model.dac);
    host.drop();
    await controller.connectHost(credentials);
    receive(id: 0x73); // Gleicher USB-Name, andere Protokoll-ID.
    expect(controller.hostReconnecting, isFalse);
    expect(controller.model, Adi2Model.pro4);
    expect(controller.device, isNotNull);
    await cleanup(tester);
  });

  testWidgets(
    'Hauptansicht bleibt mit übersetztem Neuverbindungsstatus stehen',
    (tester) async {
      final language = AppLang.instance.language;
      addTearDown(() => AppLang.instance.language = language);
      AppLang.instance.language = AppLanguage.de;
      await controller.start();
      await controller.connectHost(credentials);
      receive();
      final np = NowPlaying();
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(ctrl: controller, np: np),
        ),
      );
      await tester.pump();
      host.failConnect = true;
      host.drop();
      await tester.pump();
      expect(find.text('ADI-2 Pro EX'), findsOneWidget);
      expect(find.text('Verbinde neu …'), findsOneWidget);
      expect(find.byType(ConnectPage), findsNothing);
      expect(find.byKey(const ValueKey('host-badge-menu')), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring),
        findsWidgets,
      );
      AppLang.instance.language = AppLanguage.en;
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('Reconnecting…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      np.dispose();
      await cleanup(tester);
    },
  );

  test(
    'Änderungen anderer Host-Clients kommen als normale Geräteantworten an',
    () async {
      await controller.start();
      await controller.connectHost(credentials);
      void receive(int volume, int polarity) {
        final packet = buildSetParams(0x72, [
          Adi2Param(3, OutIdx.volume, volume),
          Adi2Param(3, OutIdx.polarity, polarity),
        ]).single..[5] = Adi2Cmd.paramsToRemote;
        host.packets.add(packet);
      }

      receive(-500, 0);
      receive(-600, 2);
      expect(controller.value(3, OutIdx.volume), -600);
      expect(controller.value(3, OutIdx.polarity), 2);
      expect(controller.volGuard.isIdle, isTrue);
      receive(-550, 1);
      expect(controller.value(3, OutIdx.volume), -550);
      expect(controller.value(3, OutIdx.polarity), 1);
      expect(host.connected, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 650));
    },
  );

  test('Presetantworten anderer Clients verunreinigen den eigenen Lesevorgang nicht', () async {
    await controller.start();
    await controller.connectHost(credentials);
    final initial = buildSetParams(0x72, [
      const Adi2Param(3, OutIdx.volume, -500),
    ]).single..[5] = Adi2Cmd.paramsToRemote;
    host.packets.add(initial);
    void response(int n, int gain) {
      final packet = buildSetParams(0x72, [
        Adi2Param(Adi2Addr.presetEqL, EqIdx2.presetFlags, (n << 4) | 1),
        Adi2Param(Adi2Addr.presetEqL, 4, gain),
        Adi2Param(Adi2Addr.presetEqR, 4, -gain),
      ]).single..[5] = Adi2Cmd.paramsToRemote;
      host.packets.add(packet);
    }

    host.onSend = (bytes) {
      if (bytes[5] != Adi2Cmd.request || bytes[6] < 0x0a || bytes[6] > 0x1d) {
        return;
      }
      final n = bytes[6] - 0x0a;
      response((n + 1) % 20, 99); // Antwort auf fremde Abfrage vor unserer.
      void ownResponse() {
        response(n, n + 1);
        response((n + 1) % 20, 99); // Fremde Antwort nach unserer.
      }

      if (n == 0) {
        // Gemeinsame Warteschlange plus Statuspause dürfen länger als 2 s dauern.
        Timer(const Duration(milliseconds: 2100), ownResponse);
      } else {
        ownResponse();
      }
    };
    final presets = await controller.readEqPresets();
    expect(presets, hasLength(20));
    for (var n = 0; n < 20; n++) {
      expect(presets[n].left[4], n + 1);
      expect(presets[n].right[4], -n - 1);
    }
  });

  test('busy erklärt das Clientlimit auf Deutsch und Englisch', () {
    final previous = AppLang.instance.language;
    addTearDown(() => AppLang.instance.language = previous);
    AppLang.instance.language = AppLanguage.de;
    expect(
      hostErrorText('FormatException: busy'),
      'Zu viele Clients am Host verbunden (maximal 4)',
    );
    AppLang.instance.language = AppLanguage.en;
    expect(
      hostErrorText('FormatException: busy'),
      'Too many clients connected to the host (maximum 4)',
    );
    expect(hostErrorText('usb_busy'), 'USB MIDI is busy on the host');
  });

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

  testWidgets('Langdruck-Menü entfernt die Kopplung und trennt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await controller.start();
    await controller.savePairedHost(credentials);
    await controller.connectHost(credentials);
    expect(controller.hostId, credentials.host.id);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHostMenu(context, controller),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-menu-manage')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-menu-forget')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-menu-forget-confirm')));
    await tester.pumpAndSettle();
    expect(controller.pairedHosts, isEmpty);
    expect(controller.viaHost, isFalse);
    controller.dispose();
    disposed = true;
  });

  test(
    'Pausierte Host-Verbindung verbindet nicht automatisch, Fortsetzen schon',
    () async {
      SharedPreferences.setMockInitialValues({});
      await controller.start();
      await controller.savePairedHost(credentials);
      await controller.connectHost(credentials);
      expect(controller.viaHost, isTrue);
      receive();
      await controller.pauseHost();
      expect(controller.model, isNull);
      expect(controller.hostReconnecting, isFalse);
      expect(controller.viaHost, isFalse);
      expect(controller.hostPaused, isTrue);
      controller.setHostForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.viaHost, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool('host_paused'),
        isTrue,
      );
      await controller.resumeHost();
      expect(controller.hostPaused, isFalse);
      expect(controller.viaHost, isTrue);
    },
  );
}
