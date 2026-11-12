import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter/foundation.dart';

import 'host_log.dart';
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
  String? deviceId, clientName;
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
  // Enthält auch reservierte Plätze während midi.open().
  final Set<_Peer> _sessions = {};
  static const maxSessions = 4;
  String? _deviceName;
  Future<void> _usbWork = Future.value();
  Timer? _closeTimer;
  Timer? _leaseTimer;
  bool _stopping = false;
  bool _usbOpen = false;
  int _usbGeneration = 0;

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
  List<String> get connectedNames => List.unmodifiable([
    for (final peer in _sessions)
      if (peer.envelope != null) peer.clientName!,
  ]);
  int get port => _server?.port ?? 0;

  // Include handshakes and authentication before midi.open() has completed.
  bool get hasSession => _peers.isNotEmpty || _sessions.isNotEmpty;
  bool get isMidiOpen => _usbOpen;

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
        if (!_usbOpen || _sessions.isEmpty) return;
        _deviceModel = parseSysex(bytes)?.deviceId ?? _deviceModel;
        _lastDeviceRx = _clock.elapsed;
        filter.observe(bytes);
        final payload = {'data': base64Encode(bytes)};
        for (final peer in _sessions.toList()) {
          if (peer.envelope != null) _send(peer, 'midi', payload);
        }
      },
      onError: (Object error) {
        usbLost();
      },
    );
    _pollTimer ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      _poll();
    });
    _leaseTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      for (final peer in _sessions.toList()) {
        if (peer.envelope == null) continue;
        if (_sessionTimedOut(peer)) {
          HostLog.write(
            'Client ${peer.clientName ?? '?'} getrennt: kein Lebenszeichen',
          );
          _send(peer, 'session_expired');
          _drop(peer);
        } else if (_leaseExpired(peer)) {
          // Nur die Freigabe zum Anheben endet; die Verbindung bleibt.
          filter.release(peer);
        }
      }
    });
  }

  // Bis zur ersten Antwort werden die Modell-Probes der Apps gesammelt.
  // Danach gibt es unabhängig von der Clientzahl genau einen Abfragezyklus.
  final Set<int> _probeModels = {};
  int _probeIndex = 0;
  final Map<String, Uint8List> _requests = {};
  Uint8List? _specificRequest;
  static const presetQuiet = Duration(milliseconds: 250);

  void _request(Uint8List bytes) {
    if (bytes.length == 8 && bytes[6] == 0x09) {
      _probeModels.add(bytes[4]);
    } else {
      // Presets/Namen gehören nicht zu Request All. Identische laufende oder
      // wartende Requests zusammenfassen, andere nach Antwortende senden.
      final key = base64Encode(bytes);
      if (_specificRequest != null &&
          key == base64Encode(_specificRequest!) &&
          _clock.elapsed - _lastPoll < presetQuiet) {
        return;
      }
      if (_requests.length < 32) _requests[key] = bytes;
    }
    _poll();
  }

  void _poll() {
    if (!_usbOpen || !_sessions.any((p) => p.envelope != null)) return;
    final now = _clock.elapsed;
    final specific = _specificRequest != null;
    if (specific &&
        (now - _lastPoll < presetQuiet || now - _lastDeviceRx < presetQuiet)) {
      return;
    }
    if (!pollDue(
      now,
      _lastDeviceRx,
      _lastPoll,
      waitForFull: specific || _requests.isNotEmpty || _quick == 0,
    )) {
      return;
    }
    Uint8List bytes;
    if (_requests.isNotEmpty) {
      final key = _requests.keys.first;
      bytes = _requests.remove(key)!;
      _specificRequest = bytes;
      _quick = 0;
    } else {
      final models = _probeModels.toList();
      final model =
          _deviceModel ??
          (models.isEmpty ? null : models[_probeIndex++ % models.length]);
      if (model == null) return;
      bytes = buildRequestAll(model);
      _specificRequest = null;
      _quick = (_quick + 1) % (quickPolls + 1);
    }
    _lastPoll = now;
    midi.send(bytes);
  }

  /// Nach einer Änderung sofort abfragen und die vollständige Antwort
  /// (~0,7 s, EQ und Dim stehen hinten) ohne schnelle Folgeabfragen
  /// durchlaufen lassen. Das Gerät bleibt die Quelle: Andere Clients sehen
  /// die Änderung erst, wenn das Gerät sie meldet.
  void _pollAfterWrite() {
    if (_specificRequest != null || _requests.isNotEmpty) return;
    _quick = quickPolls;
    final now = _clock.elapsed;
    if (now - _lastPoll >= afterWriteGap) _lastPoll = now - pollInterval;
  }

  /// Mindestabstand der Sofortabfrage zur vorigen Abfrage, damit eine
  /// Lautstärkerampe nicht jede Antwort abbricht.
  static const afterWriteGap = Duration(milliseconds: 50);

  void _resetDeviceState() {
    filter.reset();
    _deviceModel = null;
    _probeModels.clear();
    _probeIndex = 0;
    _requests.clear();
    _specificRequest = null;
    _lastDeviceRx = _lastPoll = _clock.elapsed;
    _quick = 0;
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
    _send(peer, 'hello', {
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
        if (peer.envelope != null && peer.active) {
          HostLog.write('Client ${peer.clientName ?? '?'}: Verbindung beendet');
        }
        _drop(peer);
      },
      onError: (Object error) {
        timeout.cancel();
        HostLog.write('Client ${peer.clientName ?? '?'}: Socketfehler $error');
        _drop(peer);
      },
    );
  }

  /// Verbindung erst nach längerer Funkstille trennen. WLAN-Pakete kommen
  /// oft über eine Sekunde verzögert; der Lautstärkeschutz hängt allein an
  /// der kurzen Freigabe ([hostGrantLifetime]).
  static const sessionTimeout = Duration(seconds: 6);

  bool _sessionTimedOut(_Peer peer) {
    final last = peer.lastHeartbeat ?? peer.authenticatedAt;
    return last != null && _clock.elapsed - last >= sessionTimeout;
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
        if (!_sessions.contains(peer) ||
            !pairing.devices.containsKey(peer.deviceId) ||
            _sessionTimedOut(peer)) {
          _drop(peer);
          return;
        }
        final data = peer.envelope!.open(message);
        switch (data['type']) {
          case 'heartbeat':
            peer.lastHeartbeat = _clock.elapsed;
            filter.heartbeat(peer);
          case 'release':
            filter.release(peer);
            _drop(peer);
          case 'midi':
            if (!_usbOpen) {
              _send(peer, 'usb_missing');
              return;
            }
            final bytes = filter.filter(decodeMidi(data['data']), client: peer);
            if (filter.limited) _send(peer, 'volume_limited');
            if (bytes != null && peer.active && _sessions.contains(peer)) {
              if (bytes[5] == Adi2Cmd.request) {
                _request(bytes);
              } else {
                midi.send(bytes);
                _pollAfterWrite();
              }
            }
          default:
            throw const FormatException('Unbekannter Nachrichtentyp');
        }
        return;
      }
      if (message['type'] == 'pair') {
        final device = pairing.redeem(
          message['code'] as String,
          message['deviceId'] as String,
          message['name'] as String,
        );
        if (device == null) {
          _send(peer, 'not_paired');
          _drop(peer);
          return;
        }
        try {
          await persist();
        } catch (_) {
          pairing.revoke(device.id);
          rethrow;
        }
        _send(peer, 'paired', {'key': device.key});
        _drop(peer);
        notifyListeners();
        return;
      }
      if (message['type'] != 'auth' ||
          DateTime.now().difference(peer.created) >=
              const Duration(seconds: 10)) {
        _send(peer, 'not_paired');
        _drop(peer);
        return;
      }
      final device = pairing.devices[message['deviceId']];
      if (device == null) {
        _send(peer, 'not_paired');
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
        _send(peer, 'not_paired');
        _drop(peer);
        return;
      }
      if (_sessions.length >= maxSessions) {
        _send(peer, 'busy');
        _drop(peer);
        return;
      }
      _sessions.add(peer); // vor dem ersten await reservieren
      peer.deviceId = device.id;
      peer.clientName = device.name;
      final usbGeneration = _usbGeneration;
      _closeTimer?.cancel();
      _usbWork = _usbWork.catchError((Object _) {}).then((_) async {
        if (!peer.active || !_sessions.contains(peer) || _stopping) return;
        if (!_usbOpen) {
          final deviceName = await midi.open();
          // USB-Verlust/Abbruch während open darf keine Sitzung wiederbeleben.
          if (_sessions.isEmpty ||
              _stopping ||
              usbGeneration != _usbGeneration) {
            await midi.close();
            return;
          }
          _deviceName = deviceName;
          _usbOpen = true;
        }
      });
      try {
        await _usbWork;
      } catch (error) {
        final type = error is HostUsbException ? error.type : 'usb_busy';
        status = type == 'usb_missing'
            ? 'Kein ADI-2 gefunden'
            : 'USB-MIDI belegt';
        _send(peer, type);
        _drop(peer);
        notifyListeners();
        return;
      }
      if (!peer.active || !_sessions.contains(peer) || _stopping || !_usbOpen) {
        return;
      }
      if (!_send(peer, 'authenticated', {
        'deviceName': _deviceName!,
        'proof': hostMac(device.key, ['server', ...context]),
      })) {
        return;
      }
      peer.envelope = HostEnvelope(
        sessionKey(device.key, context),
        outgoing: 'server',
        incoming: 'client',
      );
      peer.authenticatedAt = _clock.elapsed;
      status = 'Clients verbunden';
      notifyListeners();
    } catch (error) {
      HostLog.write('Client ${peer.clientName ?? '?'} getrennt: $error');
      _drop(peer);
    }
  }

  bool _send(
    _Peer peer,
    String type, [
    Map<String, dynamic> payload = const {},
  ]) {
    try {
      peer.send(type, payload);
      return true;
    } catch (_) {
      // Ein bereits schließender Socket darf den Broadcast nicht unterbrechen.
      _drop(peer);
      return false;
    }
  }

  void _drop(_Peer peer) {
    if (!peer.active) return;
    peer.active = false;
    _peers.remove(peer);
    unawaited(peer.socket.close());
    if (!_sessions.remove(peer)) return;
    filter.release(peer);
    if (_sessions.isEmpty) {
      _resetDeviceState();
      if (status == 'Clients verbunden') status = 'Bereit';
      _closeTimer?.cancel();
      _closeTimer = Timer(closeDelay, () {
        _usbWork = _usbWork.catchError((Object _) {}).then((_) async {
          if (_sessions.isEmpty) {
            _usbOpen = false;
            _deviceName = null;
            await midi.close();
          }
        });
      });
    }
    notifyListeners();
  }

  void usbLost() {
    _usbGeneration++;
    _resetDeviceState();
    _usbOpen = false;
    _deviceName = null;
    status = 'Kein ADI-2 gefunden';
    _usbWork = _usbWork.catchError((Object _) {}).then((_) => midi.close());
    for (final peer in _sessions.toList()) {
      _send(peer, 'usb_missing');
      _drop(peer);
    }
    notifyListeners();
  }

  Future<void> revoke(String deviceId) async {
    final previous = pairing.devices[deviceId];
    pairing.revoke(deviceId);
    for (final peer in _sessions.toList()) {
      if (peer.deviceId == deviceId) {
        _send(peer, 'revoked');
        _drop(peer);
      }
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
