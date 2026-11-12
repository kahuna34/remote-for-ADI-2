import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adi2_host/desktop_midi.dart';
import 'package:adi2_host/host_server.dart';
import 'package:adi2_remote/host/host_client.dart';
import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:adi2_remote/protocol/adi2_params.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

/// Vollständige Duplex-Nachrichten und Schließen über die WebSocket-API.
/// TCP-Bindung bleibt eine gesonderte Plattformprüfung.
class _Socket extends Stream<dynamic> implements WebSocket {
  final _input = StreamController<dynamic>();
  late _Socket peer;
  bool _closed = false, rejectWrites = false;
  @override
  Duration? pingInterval;
  @override
  void add(dynamic data) {
    if (_closed || rejectWrites) throw StateError('closed');
    peer._input.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    peer._closed = true;
    unawaited(_input.close());
    unawaited(peer._input.close());
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Midi implements HostMidiPort {
  int opens = 0, closes = 0;
  bool missing = false;
  Completer<void>? opening;
  final sent = <Uint8List>[];
  final responses = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get packets => responses.stream;
  @override
  Future<String> open() async {
    opens++;
    if (opening != null) await opening!.future;
    if (missing) throw const HostUsbException('usb_missing');
    return 'ADI-2 Pro (56010042)';
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  void send(Uint8List bytes) {
    sent.add(bytes);
  }
}

void main() {
  late HostServer server;
  late HostPairing pairing;
  late _Midi midi;
  late HostEndpoint endpoint;
  Future<WebSocket> connectSocket(Uri uri) async {
    final client = _Socket(), host = _Socket();
    client.peer = host;
    host.peer = client;
    server.accept(host);
    return client;
  }

  setUp(() async {
    midi = _Midi();
    pairing = HostPairing();
    server = HostServer(
      id: 'host',
      name: 'Computer',
      pairing: pairing,
      midi: midi,
      persist: () async {},
      closeDelay: const Duration(milliseconds: 30),
    );
    endpoint = HostEndpoint(
      id: 'host',
      name: 'Computer',
      address: '127.0.0.1',
      port: hostDefaultPort,
    );
  });
  tearDown(() async {
    await server.stop();
    await midi.responses.close();
  });

  Future<HostCredentials> pair([String name = 'Handy']) => HostClient.pair(
    endpoint,
    pairing.issue(),
    name,
    connectSocket: connectSocket,
  );

  test('Belegter TCP-Port erhält einen erreichbaren Ausweichport', () async {
    final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => occupied.close(force: true));
    await server.start(
      address: InternetAddress.loopbackIPv4,
      port: occupied.port,
    );
    expect(server.port, greaterThan(0));
    expect(server.port, isNot(occupied.port));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        path: '/missing',
      ),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.notFound);
    await response.drain<void>();
  });

  test(
    'Ungekoppelter Client erhält keine MIDI-Weiterleitung und kein USB',
    () async {
      final socket = await connectSocket(endpoint.uri);
      final messages = StreamIterator<dynamic>(socket);
      await messages.moveNext();
      socket.add(
        jsonEncode({
          'type': 'midi',
          'data': base64Encode(buildRequestAll(0x72)),
        }),
      );
      await messages.moveNext();
      expect(decodeHostMessage(messages.current)['type'], 'not_paired');
      expect(midi.opens, 0);
      expect(midi.sent, isEmpty);
      await messages.cancel();
      await socket.close();
    },
  );

  test('Kopplung während Sitzung, gemeinsamer Port, Befehle und Antworten beider Clients', () async {
    final credentials = await pair();
    expect(midi.opens, 0);
    final first = HostClient(connectSocket: connectSocket);
    final second = HostClient(connectSocket: connectSocket);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.connect(credentials);
    expect(midi.opens, 1);
    expect(first.deviceName, 'ADI-2 Pro (56010042)');
    final tablet = await pair('Tablet');
    await second.connect(tablet);
    expect(second.deviceName, first.deviceName);
    expect(server.connectedNames, ['Handy', 'Tablet']);
    expect(midi.opens, 1);
    final a = buildSetParams(0x72, [const Adi2Param(0, 1, 1)]).single;
    final b = buildSetParams(0x72, [const Adi2Param(0, 1, 2)]).single;
    first.sendMidi(a);
    second.sendMidi(b);
    await _until(() => midi.sent.length >= 2);
    expect(midi.sent, [a, b]);
    final packet = first.packets.stream.first;
    final packet2 = second.packets.stream.first;
    midi.responses.add(buildRequestAll(0x72));
    expect(
      await packet.timeout(const Duration(seconds: 1)),
      buildRequestAll(0x72),
    );
    expect(await packet2, buildRequestAll(0x72));
    first.disconnect();
    await _until(() => server.connectedNames.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(midi.closes, 0);
    expect(second.connected, isTrue);
    expect(server.connectedNames, ['Tablet']);
    second.disconnect();
    await _until(() => midi.closes == 1);
    expect(midi.closes, 1);
  });

  test('Vier parallele Anmeldungen teilen open, fünfter busy, Koppeln bleibt möglich', () async {
    final credentials = [for (var i = 0; i < 5; i++) await pair('Client $i')];
    final clients = [
      for (var i = 0; i < 5; i++) HostClient(connectSocket: connectSocket),
    ];
    for (final client in clients) {
      addTearDown(client.dispose);
    }
    midi.opening = Completer<void>();
    final connecting = [
      for (var i = 0; i < 4; i++) clients[i].connect(credentials[i]),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(midi.opens, 1);
    await expectLater(
      clients[4].connect(credentials[4]),
      throwsA(predicate((e) => e.toString().contains('busy'))),
    );
    expect((await pair('Weiteres Tablet')).deviceId, isNotEmpty);
    midi.opening!.complete();
    await Future.wait(connecting);
    expect(server.connectedNames, [
      'Client 0',
      'Client 1',
      'Client 2',
      'Client 3',
    ]);
    expect(midi.opens, 1);
    // Auch bei vier bereits authentifizierten Sitzungen weiter koppeln.
    await pair('Noch ein Telefon');
    await expectLater(
      clients[4].connect(credentials[4]),
      throwsA(predicate((e) => e.toString().contains('busy'))),
    );
    clients[0].disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await clients[4].connect(credentials[4]);
    expect(midi.opens, 1);
    expect(server.connectedNames, [
      'Client 1',
      'Client 2',
      'Client 3',
      'Client 4',
    ]);
  });

  test(
    'Port wird während closeDelay ohne erneutes open wiederverwendet',
    () async {
      final credentials = await pair();
      final client = HostClient(connectSocket: connectSocket);
      addTearDown(client.dispose);
      await client.connect(credentials);
      client.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await client.connect(credentials);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(midi.opens, 1);
      expect(midi.closes, 0);
      expect(server.isMidiOpen, isTrue);
    },
  );

  test(
    'Neue Sitzung und Release löschen keinen Gerätestand anderer Clients',
    () async {
      final first = HostClient(connectSocket: connectSocket);
      final second = HostClient(connectSocket: connectSocket);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.connect(await pair());
      final observed = buildSetParams(0x72, [
        const Adi2Param(3, OutIdx.volume, -400),
      ]).single..[5] = Adi2Cmd.paramsToRemote;
      midi.responses.add(observed);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await second.connect(await pair('Tablet'));
      first.setForeground(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(second.connected, isTrue);
      expect(server.filter.granted, isTrue);
      final lower = buildSetParams(0x72, [
        const Adi2Param(3, OutIdx.volume, -600),
      ]).single;
      second.sendMidi(lower);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(midi.sent, contains(equals(lower)));
      expect(midi.closes, 0);
    },
  );

  test('USB-Verlust wird allen Sitzungen gemeldet', () async {
    final clients = [
      HostClient(connectSocket: connectSocket),
      HostClient(connectSocket: connectSocket),
    ];
    for (final client in clients) {
      addTearDown(client.dispose);
      await client.connect(await pair());
    }
    server.usbLost();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final client in clients) {
      expect(client.connected, isFalse);
      expect(client.error, contains('usb_missing'));
    }
    expect(server.connectedNames, isEmpty);
    expect(server.filter.granted, isFalse);
    expect(server.isMidiOpen, isFalse);
  });

  test(
    'Client-Vollabfragen vervielfachen oder unterbrechen den Host-Zyklus nicht',
    () async {
      final clients = [
        HostClient(connectSocket: connectSocket),
        HostClient(connectSocket: connectSocket),
      ];
      for (final client in clients) {
        addTearDown(client.dispose);
        await client.connect(await pair());
      }
      final request = buildRequestAll(0x72);
      for (var i = 0; i < 20; i++) {
        for (final client in clients) {
          client.sendMidi(request);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(midi.sent, [request]);
      // Nach vier schnellen Folgeabfragen ist eine vollständige Antwort dran.
      while (midi.sent.length < HostServer.quickPolls + 1) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final before = midi.sent.length;
      final response = buildSetParams(0x72, [const Adi2Param(0, 1, 1)]).single
        ..[5] = Adi2Cmd.paramsToRemote;
      for (var i = 0; i < 20; i++) {
        midi.responses.add(response);
        for (final client in clients) {
          client.sendMidi(request);
        }
        // Deutlich unter der 40-ms-Ruhezeit, damit Testlast nicht als
        // Antwortpause zählt.
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      expect(midi.sent.length, before);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(midi.sent.length, greaterThan(before));
    },
  );

  test(
    'Gezielte Presetabfragen bleiben erhalten und werden zusammengefasst',
    () async {
      final first = HostClient(connectSocket: connectSocket);
      final second = HostClient(connectSocket: connectSocket);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.connect(await pair());
      await second.connect(await pair());
      final request = buildRequestEqPreset(0x72, 3);
      first.sendMidi(request);
      second.sendMidi(request);
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(midi.sent, [request]);
      first.sendMidi(request);
      second.sendMidi(buildRequestAll(0x72));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(midi.sent, [request]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(midi.sent.where((b) => b[6] == 0x0d).length, 1);
      expect(midi.sent, contains(equals(buildRequestAll(0x72))));
    },
  );

  test(
    'Defekter Client-Socket unterbricht den Broadcast an andere nicht',
    () async {
      late _Socket firstWire;
      final first = HostClient(
        connectSocket: (uri) async {
          firstWire = await connectSocket(uri) as _Socket;
          return firstWire;
        },
      );
      final second = HostClient(connectSocket: connectSocket);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.connect(await pair('Telefon'));
      await second.connect(await pair('Tablet'));
      firstWire.peer.rejectWrites = true;
      final packet = second.packets.stream.first;
      final response = buildSetParams(0x72, [const Adi2Param(0, 1, 1)]).single
        ..[5] = Adi2Cmd.paramsToRemote;
      midi.responses.add(response);
      expect(await packet.timeout(const Duration(seconds: 1)), response);
      expect(server.connectedNames, ['Tablet']);
      expect(second.connected, isTrue);
      expect(midi.closes, 0);
    },
  );

  test('Widerruf beendet Sitzung und verhindert erneute Anmeldung', () async {
    final credentials = await pair();
    final client = HostClient(connectSocket: connectSocket);
    addTearDown(client.dispose);
    await client.connect(credentials);
    await server.revoke(credentials.deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.connected, isFalse);
    await expectLater(
      client.connect(credentials),
      throwsA(predicate((e) => e.toString().contains('not_paired'))),
    );
  });

  test('USB fehlt wird an Smartphone und Status gemeldet', () async {
    final credentials = await pair();
    midi.missing = true;
    final client = HostClient(connectSocket: connectSocket);
    addTearDown(client.dispose);
    await expectLater(
      client.connect(credentials),
      throwsA(predicate((e) => e.toString().contains('usb_missing'))),
    );
    expect(server.status, 'Kein ADI-2 gefunden');
    expect(midi.sent, isEmpty);
  });

  test('Client-Transport verwirft Offline-Senden bei neuer Sitzung', () async {
    final credentials = await pair();
    final client = HostClient(connectSocket: connectSocket);
    addTearDown(client.dispose);
    await client.connect(credentials);
    client.disconnect();
    client.sendMidi(buildRequestAll(0x71));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.connect(credentials);
    final command = buildSetParams(0x72, [const Adi2Param(0, 1, 1)]).single;
    client.sendMidi(command);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(midi.sent, [command]);
  });

  test(
    'Hintergrundfreigabe beendet die Sitzung, USB-Verlust stoppt sie ebenfalls',
    () async {
      final credentials = await pair();
      final client = HostClient(connectSocket: connectSocket);
      addTearDown(client.dispose);
      await client.connect(credentials);
      client.setForeground(false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.connected, isFalse);
      expect(server.filter.granted, isFalse);
      client.setForeground(true);
      await client.connect(credentials);
      server.usbLost();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.connected, isFalse);
      expect(server.filter.granted, isFalse);
      expect(server.status, 'Kein ADI-2 gefunden');
    },
  );

  test('Kurz ausbleibendes Lebenszeichen beendet nur die Freigabe, nicht die Sitzung', () async {
    final credentials = await pair();
    final other = HostClient(connectSocket: connectSocket);
    addTearDown(other.dispose);
    await other.connect(await pair('Tablet'));
    final socket = await connectSocket(endpoint.uri);
    final messages = StreamIterator<dynamic>(socket);
    await messages.moveNext();
    final hello = decodeHostMessage(messages.current);
    final context = authContext(
      endpoint.id,
      credentials.deviceId,
      hello['challenge'] as String,
      randomToken(),
    );
    socket.add(
      jsonEncode({
        'type': 'auth',
        'deviceId': credentials.deviceId,
        'nonce': context.last,
        'proof': hostMac(credentials.key, ['client', ...context]),
      }),
    );
    await messages.moveNext();
    expect(decodeHostMessage(messages.current)['type'], 'authenticated');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    // WLAN-Aussetzer über 1 s trennen nicht mehr; erst nach
    // HostServer.sessionTimeout ohne Lebenszeichen.
    expect(server.connectedNames, hasLength(2));
    expect(HostServer.sessionTimeout, const Duration(seconds: 6));
    expect(other.connected, isTrue);
    expect(midi.closes, 0);
    expect(server.filter.granted, isTrue);
    expect(midi.sent, isEmpty);
    await messages.cancel();
    await socket.close();
  });

  test('Abbruch während USB-Öffnen gibt den Port wieder frei', () async {
    final credentials = await pair();
    midi.opening = Completer<void>();
    final client = HostClient(connectSocket: connectSocket);
    addTearDown(client.dispose);
    final connecting = client.connect(credentials);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final cancelled = connecting;
    client.disconnect();
    midi.opening!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(midi.closes, greaterThanOrEqualTo(1));
    await cancelled;
  }, timeout: const Timeout(Duration(seconds: 12)));

  test('USB-Verlust während open belebt keine alte Anmeldung wieder', () async {
    final credentials = await pair();
    midi.opening = Completer<void>();
    final client = HostClient(connectSocket: connectSocket);
    addTearDown(client.dispose);
    final rejected = expectLater(
      client.connect(credentials),
      throwsA(predicate((e) => e.toString().contains('usb_missing'))),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    server.usbLost();
    await rejected;
    final next = HostClient(connectSocket: connectSocket);
    addTearDown(next.dispose);
    final reconnecting = next.connect(credentials);
    midi.opening!.complete();
    await reconnecting;
    expect(client.connected, isFalse);
    expect(next.connected, isTrue);
    expect(midi.opens, 2);
    expect(server.connectedNames, ['Handy']);
  });

  test(
    'Widerruf eines Clients lässt andere Sitzungen und ihren Port bestehen',
    () async {
      final credentials = await pair('Telefon');
      final first = HostClient(connectSocket: connectSocket);
      final second = HostClient(connectSocket: connectSocket);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.connect(credentials);
      await second.connect(await pair('Tablet'));
      await server.revoke(credentials.deviceId);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(first.connected, isFalse);
      expect(second.connected, isTrue);
      expect(server.connectedNames, ['Tablet']);
      expect(server.filter.granted, isTrue);
      expect(midi.closes, 0);
    },
  );

  test('Abfrage ruht am Ende jedes Zyklus für die Statusmeldung', () {
    bool at(int ms) => HostServer.pollActiveAt(Duration(milliseconds: ms));
    expect(at(0), isTrue);
    expect(at(8600), isTrue);
    expect(at(8700), isFalse);
    expect(at(9999), isFalse);
    expect(at(10000), isTrue);
    expect(
      HostServer.pollCycle - HostServer.pollPause,
      greaterThan(HostServer.pollInterval),
    );
  });

  test('Mac-Portname wird um den USB-Namen mit Seriennummer ergänzt', () {
    const ioreg = '''
  |   "USB Product Name" = "ADI-2 DAC (52000001)"
  |   "USB Product Name" = "Keyboard"
''';
    final names = DesktopMidi.parseUsbProductNames(ioreg);
    expect(names, ['ADI-2 DAC (52000001)']);
    expect(DesktopMidi.withUsbName('Port 1', names), 'ADI-2 DAC (52000001)');
    expect(
      DesktopMidi.withUsbName('ADI-2 Pro (56010042)', names),
      'ADI-2 Pro (56010042)',
    );
    expect(
      DesktopMidi.withUsbName('Port 1', [...names, 'ADI-2 Pro (56010042)']),
      'Port 1',
    );
    expect(DesktopMidi.withUsbName('Port 1', const []), 'Port 1');
  });

  test('Neue Abfrage erst nach vollständiger Antwort des Geräts', () {
    Duration ms(int v) => Duration(milliseconds: v);
    // Gerät sendet noch (letzte Nachricht vor 10 ms): warten.
    expect(HostServer.pollDue(ms(500), ms(490), ms(300)), isFalse);
    // Still seit 40 ms und letzte Abfrage lang genug her: fragen.
    expect(HostServer.pollDue(ms(500), ms(460), ms(300)), isTrue);
    // Zu kurz nach der letzten Abfrage: warten.
    expect(HostServer.pollDue(ms(500), ms(400), ms(450)), isFalse);
    // In der Statuspause nie.
    expect(HostServer.pollDue(ms(9000), ms(0), ms(0)), isFalse);
  });

  test('Menüname des erkannten ADI-2', () {
    expect(
      DesktopMidi.displayName('ADI-2 DAC (52000001)'),
      'ADI-2 DAC (52000001)',
    );
    expect(
      DesktopMidi.displayName('ADI-2 Pro (56010042)'),
      'ADI-2 Pro EX (56010042)',
    );
    expect(
      DesktopMidi.displayName('ADI-2 Pro (53000001)'),
      'ADI-2 Pro (53000001)',
    );
    expect(
      DesktopMidi.displayName('ADI-2/4 Pro SE (55000001) Port 1'),
      'ADI-2/4 Pro SE (55000001)',
    );
    expect(DesktopMidi.displayName('Port 1'), 'ADI-2');
  });

  test(
    'Nach einer Änderung fragt der Host sofort ab und lässt die Antwort laufen',
    () async {
      final client = HostClient(connectSocket: connectSocket);
      addTearDown(client.dispose);
      await client.connect(await pair());
      final request = buildRequestAll(0x72);
      final response = buildSetParams(0x72, [const Adi2Param(0, 1, 1)]).single
        ..[5] = Adi2Cmd.paramsToRemote;
      // Gerät bekannt machen und den laufenden Zyklus in eine Antwort führen.
      midi.responses.add(response);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final command = buildSetParams(0x72, [
        const Adi2Param(Adi2Addr.line, OutIdx.mute, 1),
      ]).single;
      final before = midi.sent.length;
      client.sendMidi(command);
      // Das Gerät antwortet laufend (wie bei einer vollständigen Antwort).
      await Future<void>.delayed(const Duration(milliseconds: 30));
      for (var i = 0; i < 12; i++) {
        midi.responses.add(response);
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      final sent = midi.sent.sublist(before);
      expect(sent.first, command);
      // Genau eine Sofortabfrage; die laufende Antwort wird nicht abgebrochen.
      expect(sent.skip(1).where((m) => listEquals(m, request)), hasLength(1));
    },
  );
}

/// Wartet auf einen Zustand statt auf eine feste Zeit (langsame CI-Rechner).
Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
