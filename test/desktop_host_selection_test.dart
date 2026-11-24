import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_remote/desktop/desktop_host_selection.dart';
import 'package:adi2_remote/desktop/desktop_windows.dart';
import 'package:adi2_remote/device/adi2_controller.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/l10n/l10n.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:adi2_remote/ui/home_page.dart';
import 'package:adi2_remote/ui/host_connect_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const local = HostCredentials(
  HostEndpoint(id: 'B', name: 'Computer B', address: '127.0.0.1', port: 47321),
  'private-ui',
  'local-key',
);
const remote = HostCredentials(
  HostEndpoint(
    id: 'A',
    name: 'Computer A',
    address: '192.168.1.2',
    port: 47321,
  ),
  'computer-b',
  'remote-key',
);

class _Midi implements MidiCommand {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Desktop UI must not access MIDI');
}

class _Host extends HostClient {
  bool online = false, fail = false, missing = false;
  Completer<void>? pending;
  final connections = <HostCredentials>[];
  @override
  bool get connected => online;
  @override
  Future<void> connect(HostCredentials value) async {
    credentials = value;
    connections.add(value);
    if (pending case final wait?) {
      pending = null;
      await wait.future;
    }
    if (fail) throw StateError('Host antwortet nicht');
    if (missing) throw const FormatException('usb_missing');
    online = true;
    deviceName = 'ADI-2 Pro';
    notifyListeners();
  }

  @override
  void disconnect() {
    online = false;
    super.disconnect();
  }
}

class _Windows extends DesktopWindows {
  @override
  Future<void> open(AuxiliaryWindow kind) async {}
}

class _Controller extends Adi2Controller {
  _Controller(_Host host) : super(localHost: local, host: host, midi: _Midi());
  Completer<HostCredentials>? pairing;
  String? pairedName, pairedCode;
  HostEndpoint? pairedEndpoint;
  @override
  Future<HostCredentials> pairHost(
    HostEndpoint endpoint,
    String code,
    String name,
  ) async {
    pairedName = name;
    pairedCode = code;
    pairedEndpoint = endpoint;
    return pairing?.future ?? remote;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Local default, remote choice and return persist without storing the private local key', () async {
    final selection = DesktopHostSelection(local);
    await selection.load();
    expect(selection.current, local);
    expect(selection.isLocal, true);
    final host = _Host();
    final ctrl = Adi2Controller(
      localHost: local,
      desktopSelection: selection,
      host: host,
      midi: _Midi(),
    );
    addTearDown(ctrl.dispose);
    await ctrl.start();
    await ctrl.savePairedHost(remote);
    await ctrl.connectHost(remote);
    expect(ctrl.usesLocalHost, false);
    expect(ctrl.hostId, 'A');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DesktopHostSelection.preferenceKey), 'A');
    expect(prefs.getString('paired_hosts_v1'), isNot(contains('local-key')));
    final restored = DesktopHostSelection(local);
    await restored.load();
    expect(restored.current!.toJson(), remote.toJson());
    await ctrl.connectLocalHost();
    expect(ctrl.usesLocalHost, true);
    expect(ctrl.hostId, 'B');
    expect(ctrl.pairedHosts, [remote]);
    final localAgain = DesktopHostSelection(local);
    await localAgain.load();
    expect(localAgain.current, local);
  });

  test('Desktop discovery resolves a saved host and shares its current address with windows', () async {
    final host = _Host();
    final ctrl = _Controller(host);
    addTearDown(ctrl.dispose);
    await ctrl.start();
    const resolved = HostEndpoint(
      id: 'A',
      name: 'Computer A',
      address: '192.168.1.99',
      port: 47999,
    );
    ctrl.hostDiscovery.hosts['A'] = resolved;
    await ctrl.savePairedHost(remote);
    await ctrl.connectHost(remote);
    expect(host.connections.last.host, resolved);
    expect(ctrl.desktopSelection!.current!.host, resolved);
    expect(
      (ctrl.desktopSelection!.windowCredentials()['host'] as Map)['port'],
      47999,
    );
    expect(host.connections.last.key, remote.key);
  });

  test(
    'Restart and retry keep an unavailable remote selected; own USB never wins',
    () async {
      SharedPreferences.setMockInitialValues({
        DesktopHostSelection.preferenceKey: 'A',
        'paired_hosts_v1': jsonEncode([remote.toJson()]),
      });
      final host = _Host()..fail = true;
      final ctrl = Adi2Controller(localHost: local, host: host, midi: _Midi());
      addTearDown(ctrl.dispose);
      await ctrl.start();
      expect(ctrl.desktopSelection!.current!.host.id, 'A');
      expect(ctrl.error, isNotNull);
      ctrl.setHostForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(host.connections.every((c) => c.host.id == 'A'), true);
      host.fail = false;
      await ctrl.connectLocalHost();
      expect(ctrl.usesLocalHost, true);
    },
  );

  test(
    'Missing or corrupt saved pairing requires an explicit choice',
    () async {
      SharedPreferences.setMockInitialValues({
        DesktopHostSelection.preferenceKey: 'A',
        'paired_hosts_v1': 'corrupt',
      });
      final host = _Host();
      final ctrl = Adi2Controller(localHost: local, host: host, midi: _Midi());
      addTearDown(ctrl.dispose);
      await ctrl.start();
      expect(ctrl.desktopSelection!.current, isNull);
      expect(host.connections, isEmpty);
      expect(
        ctrl.error,
        contains(
          tr(
            'Gespeicherte Host-Kopplung fehlt. Bitte Host wählen oder zu „Dieser Rechner“ wechseln.',
          ),
        ),
      );
      await ctrl.connectLocalHost();
      expect(ctrl.usesLocalHost, true);
    },
  );

  test(
    'Forgetting the selected remote never reconnects with the deleted key',
    () async {
      final ctrl = _Controller(_Host());
      addTearDown(ctrl.dispose);
      await ctrl.start();
      await ctrl.savePairedHost(remote);
      await ctrl.connectHost(remote);
      await ctrl.forgetHost('A');
      expect(ctrl.desktopSelection!.current, isNull);
      ctrl.setHostForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.viaHost, false);
    },
  );

  test('The latest choice wins concurrent selection writes', () async {
    final selection = DesktopHostSelection(local);
    await Future.wait([selection.select(remote), selection.select(local)]);
    expect(selection.current, local);
    expect(
      (await SharedPreferences.getInstance()).getString(
        DesktopHostSelection.preferenceKey,
      ),
      'B',
    );
  });

  test(
    'Switching cancels a pending connection and discards its old completion',
    () async {
      final host = _Host();
      final ctrl = _Controller(host);
      addTearDown(ctrl.dispose);
      await ctrl.start();
      final pending = Completer<void>();
      host.pending = pending;
      final opening = ctrl.connectHost(remote);
      await Future<void>.delayed(Duration.zero);
      await ctrl.connectLocalHost();
      expect(ctrl.hostId, 'B');
      pending.complete();
      await opening;
      expect(ctrl.hostId, 'B');
      expect(ctrl.desktopSelection!.isLocal, true);
    },
  );

  test('New pairing credentials supersede a pending attempt to the same desktop host', () async {
    final host = _Host();
    final ctrl = _Controller(host);
    addTearDown(ctrl.dispose);
    await ctrl.start();
    final pending = Completer<void>();
    host.pending = pending;
    final stale = ctrl.connectHost(remote);
    await Future<void>.delayed(Duration.zero);
    final repaired = HostCredentials(remote.host, 'new-device', 'new-key');
    await ctrl.connectHost(repaired);
    pending.complete();
    await stale;
    expect(ctrl.hostId, 'A');
    expect(ctrl.desktopSelection!.current!.key, 'new-key');
    expect(host.connections.last.key, 'new-key');
  });

  test('Switching hosts clears readbacks and cancels volume ramps', () async {
    final host = _Host();
    final ctrl = _Controller(host);
    addTearDown(ctrl.dispose);
    await ctrl.start();
    host.packets.add(
      buildSetParams(0x72, [const Adi2Param(3, OutIdx.volume, -500)]).single
        ..[5] = Adi2Cmd.paramsToRemote,
    );
    ctrl.setVolume(3, 0);
    expect(ctrl.volGuard.isIdle, false);
    await ctrl.connectHost(remote);
    expect(ctrl.hostId, 'A');
    expect(ctrl.volGuard.isIdle, true);
    expect(ctrl.value(3, OutIdx.volume), isNull);
    expect(ctrl.model, isNull);
    expect(ctrl.state, ConnState.waitingForDevice);
  });

  test(
    'Auxiliary controllers follow remote and local without persistence or USB',
    () async {
      final host = _Host();
      final ctrl = Adi2Controller(
        windowHost: remote,
        host: host,
        midi: _Midi(),
      );
      addTearDown(ctrl.dispose);
      await ctrl.start();
      expect(ctrl.hostId, 'A');
      expect(ctrl.usesLocalHost, false);
      await ctrl.followWindowHost(local, local: true);
      expect(ctrl.hostId, 'B');
      expect(ctrl.usesLocalHost, true);
      await ctrl.followWindowHost(remote, local: false);
      expect(ctrl.hostId, 'A');
      expect(ctrl.usesLocalHost, false);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          DesktopHostSelection.preferenceKey,
        ),
        false,
      );
    },
  );

  testWidgets(
    'Desktop discovery hides own host and exposes local choice without a camera',
    (tester) async {
      final ctrl = _Controller(_Host());
      addTearDown(ctrl.dispose);
      ctrl.hostDiscovery.hosts.addAll({'A': remote.host, 'B': local.host});
      await tester.pumpWidget(MaterialApp(home: HostConnectPage(ctrl: ctrl)));
      expect(find.text(tr('Dieser Rechner')), findsOneWidget);
      expect(find.text('Computer B'), findsOneWidget); // Local tile only.
      expect(find.text('Computer A'), findsOneWidget);
      expect(find.text(tr('QR-Code scannen')), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      await tester.tap(find.text('Computer A'));
      await tester.pump();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields[0].controller!.text, remote.host.address);
      expect(
        fields[2].controller!.text,
        Platform.localHostname.substring(
          0,
          Platform.localHostname.length.clamp(0, 100),
        ),
      );
    },
  );

  testWidgets(
    'Desktop code pairing uses entered address, port, code and computer name',
    (tester) async {
      final ctrl = _Controller(_Host());
      await ctrl.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => HostConnectPage(ctrl: ctrl),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '192.168.1.2');
      await tester.enterText(fields.at(1), '47321');
      await tester.enterText(fields.at(2), 'Studio-PC B');
      await tester.enterText(fields.at(3), '123456');
      await tester.ensureVisible(find.text(tr('Koppeln und verbinden')));
      await tester.tap(find.text(tr('Koppeln und verbinden')));
      await tester.pumpAndSettle();
      expect(ctrl.pairedCode, '123456');
      expect(ctrl.pairedName, 'Studio-PC B');
      expect(ctrl.pairedEndpoint!.address, '192.168.1.2');
      expect(ctrl.pairedEndpoint!.port, 47321);
      expect(ctrl.hostId, 'A');
      expect(ctrl.pairedHosts, [remote]);
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Returning locally cancels a still pending desktop code pairing',
    (tester) async {
      final ctrl = _Controller(_Host());
      final pairing = Completer<HostCredentials>();
      ctrl.pairing = pairing;
      await ctrl.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => HostConnectPage(ctrl: ctrl),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '192.168.1.2');
      await tester.enterText(fields.at(3), '123456');
      await tester.ensureVisible(find.text(tr('Koppeln und verbinden')));
      await tester.tap(find.text(tr('Koppeln und verbinden')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('host-select-local')),
      );
      await tester.tap(find.byKey(const ValueKey('host-select-local')));
      await tester.pumpAndSettle();
      pairing.complete(remote);
      await tester.pump();
      expect(ctrl.usesLocalHost, true);
      expect(ctrl.hostId, 'B');
      expect(ctrl.pairedHosts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('Unavailable remote offers explicit local fallback', (
    tester,
  ) async {
    final host = _Host()..fail = true;
    final ctrl = _Controller(host);
    await ctrl.start();
    await ctrl.connectHost(remote);
    await tester.pumpWidget(MaterialApp(home: ConnectPage(ctrl: ctrl)));
    expect(find.byKey(const ValueKey('host-return-local')), findsOneWidget);
    host.fail = false;
    await tester.tap(find.byKey(const ValueKey('host-return-local')));
    await tester.pump();
    expect(ctrl.usesLocalHost, true);
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'Desktop header opens the connection choice',
    (tester) async {
      tester.view.physicalSize = const Size(640, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final windows = _Windows();
      addTearDown(windows.dispose);
      final host = _Host();
      final ctrl = _Controller(host);
      final np = NowPlaying(hostOnly: true);
      addTearDown(np.dispose);
      await ctrl.start();
      host.packets.add(
        buildSetParams(0x72, [const Adi2Param(3, OutIdx.volume, -500)]).single
          ..[5] = Adi2Cmd.paramsToRemote,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(ctrl: ctrl, np: np),
        ),
      );
      final badge = find.byKey(const ValueKey('desktop-host-choice'));
      expect(badge, findsOneWidget);
      expect(find.byKey(const ValueKey('host-badge')), findsOneWidget);
      await tester.tap(badge);
      await tester.pumpAndSettle();
      expect(find.byType(HostConnectPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  test('Kein ADI-2 am eingebauten Host: stille Neuversuche ohne Springen der Anzeige', () async {
    final host = _Host()..missing = true;
    final ctrl = Adi2Controller(localHost: local, host: host, midi: _Midi());
    addTearDown(ctrl.dispose);
    await ctrl.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ctrl.state, ConnState.searching);
    final missing = ctrl.error;
    expect(missing, isNotNull);
    final seen = <(ConnState, String?)>[];
    ctrl.addListener(() => seen.add((ctrl.state, ctrl.error)));
    final before = host.connections.length;
    await Future<void>.delayed(const Duration(milliseconds: 3300));
    expect(host.connections.length, greaterThan(before));
    expect(
      seen.where((e) => e.$1 != ConnState.searching || e.$2 != missing),
      isEmpty,
    );
    // Gerät wieder da: der nächste stille Versuch verbindet normal.
    host.missing = false;
    await Future<void>.delayed(const Duration(milliseconds: 3300));
    expect(ctrl.state, isNot(ConnState.searching));
  });
}
