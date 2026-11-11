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
import 'package:flutter_test/flutter_test.dart';

/// Vollständige Duplex-Nachrichten und Schließen über die WebSocket-API.
/// TCP-Bindung bleibt eine gesonderte Plattformprüfung.
class _Socket extends Stream<dynamic> implements WebSocket {
  final _input = StreamController<dynamic>();
  late _Socket peer;
  bool _closed = false;
  @override
  Duration? pingInterval;
  @override
  void add(dynamic data) {
    if (_closed) throw StateError('closed');
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

  Future<HostCredentials> pair() => HostClient.pair(
    endpoint,
    pairing.issue(),
    'Handy',
    connectSocket: connectSocket,
  );

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

  test(
    'Kopplung öffnet USB nicht, Sitzung öffnet USB, zweiter Client belegt',
    () async {
      final credentials = await pair();
      expect(midi.opens, 0);
      final first = HostClient(connectSocket: connectSocket);
      final second = HostClient(connectSocket: connectSocket);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.connect(credentials);
      expect(midi.opens, 1);
      expect(first.deviceName, 'ADI-2 Pro (56010042)');
      await expectLater(
        second.connect(credentials),
        throwsA(predicate((e) => e.toString().contains('busy'))),
      );
      expect(midi.opens, 1);
      first.sendMidi(buildRequestAll(0x72));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(midi.sent, [buildRequestAll(0x72)]);
      final packet = first.packets.stream.first;
      midi.responses.add(buildRequestAll(0x72));
      expect(
        await packet.timeout(const Duration(seconds: 1)),
        buildRequestAll(0x72),
      );
      first.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(midi.closes, 1);
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
    client.sendMidi(buildRequestAll(0x72));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(midi.sent, [buildRequestAll(0x72)]);
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

  test(
    'Ausbleibendes Lebenszeichen schließt die authentifizierte Sitzung',
    () async {
      final credentials = await pair();
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
      expect(server.connectedName, isNull);
      expect(server.filter.granted, isFalse);
      expect(midi.sent, isEmpty);
      await messages.cancel();
      await socket.close();
    },
  );

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
}
