import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter/foundation.dart';

import 'volume_filter.dart';

abstract class HostMidiPort {
  Stream<Uint8List> get packets;
  Future<String> open();
  Future<void> close();
  void send(Uint8List data);
}

class HostUsbException implements Exception {
  const HostUsbException(this.type);
  final String type;
}

class _Peer {
  _Peer(this.socket);
  final WebSocket socket;
  final challenge = randomToken();
  final created = DateTime.now();
  HostEnvelope? envelope;
  String? deviceId;
  Duration? authenticatedAt, lastHeartbeat;
  bool active = true;
  void send(String type, [Map<String, dynamic> payload = const {}]) {
    if (!active) return;
    socket.add(
      envelope?.seal(type, payload) ?? jsonEncode({'type': type, ...payload}),
    );
  }
}

class HostServer extends ChangeNotifier {
  HostServer({
    required this.id,
    required this.name,
    required this.pairing,
    required this.midi,
    required this.persist,
    HostVolumeFilter? filter,
    this.closeDelay = const Duration(seconds: 3),
  }) : filter = filter ?? HostVolumeFilter();
  final String id, name;
  final HostPairing pairing;
  final HostMidiPort midi;
  final Future<void> Function() persist;
  final HostVolumeFilter filter;
  final Duration closeDelay;
  final Set<_Peer> _peers = {};
  final Stopwatch _clock = Stopwatch()..start();
  HttpServer? _server;
  StreamSubscription<Uint8List>? _rx;
  _Peer? _owner;
  Future<void> _usbWork = Future.value();
  Timer? _closeTimer;
  Timer? _leaseTimer;
  bool _stopping = false;
  bool _usbOpen = false;

  /// Das Gerät meldet Änderungen anderer Software (z. B. RME ADI-2 Remote)
  /// nicht von selbst. Während einer Sitzung fragt der Host daher den Stand
  /// alle 0,1 s ab und reicht die Antworten sofort an das Smartphone weiter.
  /// Jede Anfrage verschiebt aber die Statusmeldung des Geräts (etwa 1 s nach
  /// der letzten Nachricht). Deshalb ruht die Abfrage in jedem Zyklus kurz.
  static const pollInterval = Duration(milliseconds: 100);
  static const pollCycle = Duration(milliseconds: 10000);
  static const pollPause = Duration(milliseconds: 1300);
  Timer? _pollTimer;
  int? _deviceModel;
  Duration _lastDeviceRx = Duration.zero, _lastPoll = Duration.zero;

  /// Eine Abfrage beantwortet das Gerät mit mehreren Nachrichten (Ausgänge
  /// zuerst, EQ und weitere Werte danach). Eine neue Anfrage vor dem Ende
  /// bricht die Antwort ab. Deshalb erst wieder fragen, wenn es kurz still war.
  static const quietBeforePoll = Duration(milliseconds: 40);

  /// Lautstärke steht in den ersten Teilen der Antwort, EQ und Dim weiter
  /// hinten (komplette Antwort etwa 0,7 s). Deshalb im Wechsel: einige schnelle
  /// Abfragen für die Lautstärke, dann eine vollständige Antwort abwarten.
  static const quickPolls = 4;
  int _quick = 0;

  static bool pollDue(
    Duration now,
    Duration lastRx,
    Duration lastPoll, {
    bool waitForFull = true,
  }) =>
      pollActiveAt(now) &&
      now - lastPoll >= pollInterval &&
      (!waitForFull || now - lastRx >= quietBeforePoll);
  String status = 'Bereit';
  String? connectedName;
  int get port => _server?.port ?? 0;

  Future<void> start({
    InternetAddress? address,
    int port = hostDefaultPort,
  }) async {
    try {
      _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    } on SocketException {
      _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, 0);
    }
    _ensureSessionRuntime();
    _server!.listen((request) async {
      if (_stopping ||
          request.uri.path != '/adi2' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (_peers.length >= 8) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      try {
        accept(
          await WebSocketTransformer.upgrade(request, maxPayloadLength: 32768),
        );
      } catch (_) {
        // Ein abgebrochener HTTP-Handshake beendet nur diesen Verbindungsversuch.
      }
    });
  }

  /// Abfragefenster: am Ende jedes Zyklus eine Pause für die Statusmeldung.
  static bool pollActiveAt(Duration elapsed) =>
      elapsed.inMilliseconds % pollCycle.inMilliseconds <
      pollCycle.inMilliseconds - pollPause.inMilliseconds;

  void _ensureSessionRuntime() {
    _rx ??= midi.packets.listen(
      (bytes) {
        if (_owner?.envelope == null) return;
        _deviceModel = parseSysex(bytes)?.deviceId ?? _deviceModel;
        _lastDeviceRx = _clock.elapsed;
        filter.observe(bytes);
        _owner!.send('midi', {'data': base64Encode(bytes)});
      },
      onError: (Object error) {
        usbLost();
      },
    );
    _pollTimer ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      final model = _deviceModel;
      final now = _clock.elapsed;
      // Nach den schnellen Abfragen muss die letzte Antwort vollständig sein.
      final waitForFull = _quick == 0;
      if (!pollDue(now, _lastDeviceRx, _lastPoll, waitForFull: waitForFull)) {
        return;
      }
      if (model != null && _usbOpen && _owner?.envelope != null) {
        _lastPoll = now;
        _quick = (_quick + 1) % (quickPolls + 1);
        midi.send(buildRequestAll(model));
      }
    });
    _leaseTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final owner = _owner;
      if (owner != null && _leaseExpired(owner)) {
        owner.send('session_expired');
        _drop(owner);
      }
      if (!filter.granted) filter.release();
    });
  }

  /// Gemeinsamer Sitzungseinstieg für TCP-WebSockets und In-Memory-Tests.
  void accept(WebSocket socket) {
    if (_stopping) {
      unawaited(socket.close());
      return;
    }
    _ensureSessionRuntime();
    final peer = _Peer(socket);
    peer.socket.pingInterval = const Duration(seconds: 3);
    _peers.add(peer);
    peer.send('hello', {
      'hostId': id,
      'name': name,
      'challenge': peer.challenge,
    });
    final timeout = Timer(const Duration(seconds: 10), () {
      if (peer.envelope == null) _drop(peer);
    });
    // Abbruch bleibt auch während eines asynchronen USB-Öffnens sichtbar.
    // Nur Datenverarbeitung wird serialisiert, onDone pausiert dabei nie.
    var work = Future<void>.value();
    peer.socket.listen(
      (frame) {
        work = work.then((_) => _receive(peer, frame));
      },
      onDone: () {
        timeout.cancel();
        _drop(peer);
      },
      onError: (Object error) {
        timeout.cancel();
        _drop(peer);
      },
    );
  }

  bool _leaseExpired(_Peer peer) {
    final last = peer.lastHeartbeat ?? peer.authenticatedAt;
    return last != null && _clock.elapsed - last >= hostGrantLifetime;
  }

  Future<void> _receive(_Peer peer, dynamic frame) async {
    if (!peer.active || _stopping) return;
    try {
      final message = decodeHostMessage(frame);
      if (peer.envelope != null) {
        if (_owner != peer ||
            !pairing.devices.containsKey(peer.deviceId) ||
            _leaseExpired(peer)) {
          _drop(peer);
          return;
        }
        final data = peer.envelope!.open(message);
        switch (data['type']) {
          case 'heartbeat':
            peer.lastHeartbeat = _clock.elapsed;
            filter.heartbeat();
          case 'release':
            filter.release();
            _drop(peer);
          case 'midi':
            if (!_usbOpen) {
              peer.send('usb_missing');
              return;
            }
            final bytes = filter.filter(decodeMidi(data['data']));
            if (filter.limited) peer.send('volume_limited');
            if (bytes != null && peer.active && _owner == peer) {
              midi.send(bytes);
            }
          default:
            throw const FormatException('Unbekannter Nachrichtentyp');
        }
        return;
      }
      if (_owner != null) {
        peer.send('busy');
        _drop(peer);
        return;
      }
      if (message['type'] == 'pair') {
        final device = pairing.redeem(
          message['code'] as String,
          message['deviceId'] as String,
          message['name'] as String,
        );
        if (device == null) {
          peer.send('not_paired');
          _drop(peer);
          return;
        }
        try {
          await persist();
        } catch (_) {
          pairing.revoke(device.id);
          rethrow;
        }
        peer.send('paired', {'key': device.key});
        _drop(peer);
        notifyListeners();
        return;
      }
      if (message['type'] != 'auth' ||
          DateTime.now().difference(peer.created) >=
              const Duration(seconds: 10)) {
        peer.send('not_paired');
        _drop(peer);
        return;
      }
      final device = pairing.devices[message['deviceId']];
      if (device == null) {
        peer.send('not_paired');
        _drop(peer);
        return;
      }
      final context = authContext(
        id,
        device.id,
        peer.challenge,
        message['nonce'] as String,
      );
      if (!secureEquals(
        message['proof'] as String,
        hostMac(device.key, ['client', ...context]),
      )) {
        peer.send('not_paired');
        _drop(peer);
        return;
      }
      _owner = peer; // vor dem ersten await reservieren
      peer.deviceId = device.id;
      _closeTimer?.cancel();
      filter.reset();
      String? deviceName;
      _usbWork = _usbWork.then((_) async {
        if (!peer.active || _owner != peer || _stopping) return;
        deviceName = await midi.open();
        _usbOpen = true;
      });
      try {
        await _usbWork;
      } catch (error) {
        _usbWork = Future.value();
        final type = error is HostUsbException ? error.type : 'usb_busy';
        status = type == 'usb_missing'
            ? 'Kein ADI-2 gefunden'
            : 'USB-MIDI belegt';
        peer.send(type);
        _drop(peer);
        notifyListeners();
        return;
      }
      if (!peer.active || _owner != peer || _stopping || deviceName == null) {
        return;
      }
      peer.send('authenticated', {
        'deviceName': deviceName,
        'proof': hostMac(device.key, ['server', ...context]),
      });
      peer.envelope = HostEnvelope(
        sessionKey(device.key, context),
        outgoing: 'server',
        incoming: 'client',
      );
      peer.authenticatedAt = _clock.elapsed;
      connectedName = device.name;
      status = 'Smartphone verbunden';
      notifyListeners();
    } catch (_) {
      _drop(peer);
    }
  }

  void _drop(_Peer peer) {
    if (!peer.active) return;
    peer.active = false;
    _peers.remove(peer);
    unawaited(peer.socket.close());
    if (_owner != peer) return;
    _owner = null;
    connectedName = null;
    filter.reset();
    if (status == 'Smartphone verbunden') status = 'Bereit';
    _closeTimer?.cancel();
    _closeTimer = Timer(closeDelay, () {
      _usbWork = _usbWork.catchError((Object _) {}).then((_) async {
        if (_owner == null) {
          _usbOpen = false;
          await midi.close();
        }
      });
    });
    notifyListeners();
  }

  void usbLost() {
    filter.reset();
    _deviceModel = null;
    _usbOpen = false;
    status = 'Kein ADI-2 gefunden';
    final owner = _owner;
    owner?.send('usb_missing');
    if (owner != null) _drop(owner);
    notifyListeners();
  }

  Future<void> revoke(String deviceId) async {
    final previous = pairing.devices[deviceId];
    pairing.revoke(deviceId);
    final owner = _owner;
    if (owner?.deviceId == deviceId) {
      owner!.send('revoked');
      _drop(owner);
    }
    try {
      await persist();
    } catch (_) {
      if (previous != null) pairing.devices[deviceId] = previous;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _stopping = true;
    filter.reset();
    _leaseTimer?.cancel();
    _pollTimer?.cancel();
    for (final peer in _peers.toList()) {
      _drop(peer);
    }
    _closeTimer?.cancel();
    await _rx?.cancel();
    await _server?.close(force: true);
    await _usbWork.catchError((Object _) {});
    _usbOpen = false;
    await midi.close();
  }
}
