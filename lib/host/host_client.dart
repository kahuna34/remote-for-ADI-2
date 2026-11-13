import 'dart:async';

import 'host_analyzer_protocol.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'host_protocol.dart';
import 'host_player_protocol.dart';
import '../media/now_playing.dart';

class HostCredentials {
  const HostCredentials(this.host, this.deviceId, this.key);
  final HostEndpoint host;
  final String deviceId, key;
  Map<String, dynamic> toJson() => {
    'host': host.toJson(),
    'deviceId': deviceId,
    'key': key,
  };
  factory HostCredentials.fromJson(Map<String, dynamic> j) => HostCredentials(
    HostEndpoint.fromJson(j['host'] as Map<String, dynamic>),
    j['deviceId'] as String,
    j['key'] as String,
  );
}

typedef HostSocketConnector = Future<WebSocket> Function(Uri uri);

Future<WebSocket> _connectHostSocket(Uri uri) => WebSocket.connect(
  uri.toString(),
  // Keine Kompression: verschlüsselte Nutzdaten, siehe Host.
  compression: CompressionOptions.compressionOff,
);

/// Abriss verwirft die gesamte Sitzung. Die nächste Verbindung verlangt
/// einen neuen Challenge-Response und einen neuen Geräteabgleich im Controller.
class HostClient extends ChangeNotifier {
  HostClient({HostSocketConnector? connectSocket})
    : _connectSocket = connectSocket ?? _connectHostSocket;
  final HostSocketConnector _connectSocket;
  final packets = StreamController<Uint8List>.broadcast(sync: true);
  final analyzerEvents = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );

  /// Nur die Darstellung überbrücken; jede TCP-Sitzung wird neu authentifiziert.
  bool reconnecting = false;
  void setReconnecting(bool value) {
    if (reconnecting == value) return;
    reconnecting = value;
    if (!value && !connected) _clearPlayer();
    notifyListeners();
  }

  bool playerAvailable = false;
  NowPlayingInfo? playerInfo;
  final Set<Object> _playerOwners = {};
  Timer? _playerStopTimer;
  bool _playerSubscribed = false;
  void subscribePlayer(Object owner) {
    if (!playerAvailable || (!connected && !reconnecting)) return;
    _playerStopTimer?.cancel();
    _playerStopTimer = null;
    _playerOwners.add(owner);
    if (reconnecting) return;
    if (!_playerSubscribed) {
      _playerSubscribed = true;
      send('player_subscribe');
    }
  }

  void unsubscribePlayer(Object owner) {
    if (_playerOwners.remove(owner) && _playerOwners.isEmpty) {
      _playerStopTimer = Timer(const Duration(milliseconds: 500), () {
        _playerStopTimer = null;
        if (_playerSubscribed && connected) send('player_unsubscribe');
        _playerSubscribed = false;
        if (!reconnecting) playerInfo = null;
      });
    }
  }

  void playerCommand(String command) {
    if (connected &&
        !reconnecting &&
        playerAvailable &&
        _playerOwners.isNotEmpty &&
        hostPlayerCommands.contains(command)) {
      send('player_command', {'command': command});
    }
  }

  bool analyzerAvailable = false;
  int analyzerVersion = 0;
  String? analyzerPlatform;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  HostEnvelope? _envelope;
  Timer? _heartbeat;
  Completer<void>? _pendingConnection;
  bool _foreground = true;
  int _generation = 0;
  bool get connected => _envelope != null;
  String? deviceName, error;
  HostCredentials? credentials;
  String? get hostName => credentials?.host.name;

  static Future<HostCredentials> pair(
    HostEndpoint host,
    String code,
    String name, {
    HostSocketConnector? connectSocket,
  }) async {
    final socket = await (connectSocket ?? _connectHostSocket)(host.uri)
        .timeout(const Duration(seconds: 5));
    final messages = StreamIterator<dynamic>(socket);
    try {
      if (!await messages.moveNext().timeout(const Duration(seconds: 5))) {
        throw const FormatException('Host nicht erreichbar');
      }
      final hello = decodeHostMessage(messages.current);
      if (hello['type'] != 'hello' ||
          (host.id.isNotEmpty && hello['hostId'] != host.id)) {
        throw const FormatException('Host-ID stimmt nicht ueberein');
      }
      final deviceId = randomToken(16);
      socket.add(
        jsonEncode({
          'type': 'pair',
          'code': code,
          'deviceId': deviceId,
          'name': name,
        }),
      );
      if (!await messages.moveNext().timeout(const Duration(seconds: 5))) {
        throw const FormatException('Kopplung abgebrochen');
      }
      final reply = decodeHostMessage(messages.current);
      if (reply['type'] != 'paired') throw FormatException('${reply['type']}');
      return HostCredentials(
        HostEndpoint(
          id: hello['hostId'] as String,
          name: hello['name'] as String,
          address: host.address,
          port: host.port,
        ),
        deviceId,
        reply['key'] as String,
      );
    } finally {
      await messages.cancel();
      await socket.close();
    }
  }

  Future<void> connect(HostCredentials value) async {
    _disconnect(preservePresentation: reconnecting);
    credentials = value;
    error = null;
    final generation = _generation;
    final ready = Completer<void>();
    _pendingConnection = ready;
    WebSocket? socket;
    try {
      socket = await _connectSocket(value.host.uri)
          .timeout(const Duration(seconds: 5));
      if (generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      String? key;
      List<String>? context;
      _subscription = socket.listen(
        (frame) {
          if (generation != _generation) return;
          _lastReceived.reset();
          try {
            final message = decodeHostMessage(frame);
            if (_envelope != null) {
              final data = _envelope!.open(message);
              if (data['type'] == 'player_state' &&
                  playerAvailable &&
                  _playerSubscribed) {
                // Ein unlesbarer Player-Status trennt nie die Verbindung.
                try {
                  playerInfo = decodeHostPlayerState(data, playerInfo);
                  notifyListeners();
                } on FormatException catch (e) {
                  debugPrint('Player-Status verworfen: $e');
                }
              }
              if (data['type'] == 'analyzer_metadata' ||
                  data['type'] == 'analyzer_frame' ||
                  data['type'] == 'analyzer_error') {
                if (data['type'] == 'analyzer_frame') analyzerFramesReceived++;
                analyzerEvents.add(data);
              }
              if (data['type'] == 'midi') packets.add(decodeMidi(data['data']));
              if (data['type'] == 'usb_missing' ||
                  data['type'] == 'usb_busy' ||
                  data['type'] == 'revoked') {
                throw FormatException('${data['type']}');
              }
            } else if (message['type'] == 'hello') {
              if (message['hostId'] != value.host.id) {
                throw const FormatException('Host-ID stimmt nicht ueberein');
              }
              context = authContext(
                value.host.id,
                value.deviceId,
                message['challenge'] as String,
                randomToken(),
              );
              key = sessionKey(value.key, context!);
              socket!.add(
                jsonEncode({
                  'type': 'auth',
                  'deviceId': value.deviceId,
                  'nonce': context!.last,
                  'proof': hostMac(value.key, ['client', ...context!]),
                }),
              );
            } else if (message['type'] == 'authenticated' && key != null) {
              if (!secureEquals(
                message['proof'] as String,
                hostMac(value.key, ['server', ...context!]),
              )) {
                throw const FormatException('Host-Nachweis ungueltig');
              }
              deviceName = message['deviceName'] as String;
              analyzerVersion = negotiateHostAnalyzerVersion(
                message['analyzerVersion'],
              );
              analyzerAvailable = analyzerVersion > 0;
              playerAvailable =
                  negotiateHostPlayerVersion(message['playerVersion']) > 0;
              analyzerPlatform = message['analyzerPlatform'] as String?;
              _envelope = HostEnvelope(
                key!,
                outgoing: 'client',
                incoming: 'server',
              );
              _startHeartbeat();
              _startSilenceWatch(message['alive'] == true);
              ready.complete();
              notifyListeners();
            } else {
              throw FormatException('${message['type']}');
            }
          } catch (e) {
            if (!ready.isCompleted) ready.completeError(e);
            _lost(e.toString());
          }
        },
        onDone: () {
          if (generation != _generation) return;
          if (!ready.isCompleted) {
            ready.completeError(StateError('Host getrennt'));
          }
          _lost(
            'Host getrennt (Code ${socket?.closeCode}, '
            '${socket?.closeReason ?? ''})',
          );
        },
        onError: (Object e) {
          if (generation != _generation) return;
          if (!ready.isCompleted) ready.completeError(e);
          _lost(e.toString());
        },
      );
      await ready.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      if (generation == _generation) {
        _disconnect(preservePresentation: reconnecting);
      }
      rethrow;
    } finally {
      if (identical(_pendingConnection, ready)) _pendingConnection = null;
    }
  }

  final _lastReceived = Stopwatch()..start();
  Timer? _silenceWatch;

  /// Bei ausbleibenden Lebenszeichen entscheidet der Transport-Watchdog.
  /// MIDI-/Analyzer-Watchdogs dürfen ihm keinen sichtbaren Reset vorwegnehmen.
  bool get awaitingSilenceTimeout =>
      _silenceWatch != null && _lastReceived.elapsed >= hostAliveInterval * 2;

  /// Erkennt Verbindungen, bei denen nur noch die App sendet, aber vom Host
  /// nichts mehr ankommt (WLAN hält einzelne Verbindungen fest). Nur bei
  /// Hosts, die regelmäßig 'alive' senden.
  void _startSilenceWatch(bool hostSendsAlive) {
    _silenceWatch?.cancel();
    _silenceWatch = null;
    if (!hostSendsAlive) return;
    _lastReceived.reset();
    _silenceWatch = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_foreground || !connected) {
        _lastReceived.reset();
        return;
      }
      if (_lastReceived.elapsed >= hostSilenceTimeout) {
        _lost('Host antwortet nicht');
      }
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    if (!_foreground || !connected) return;
    _sendHeartbeat();
    _heartbeat = Timer.periodic(hostHeartbeatInterval, (_) => _sendHeartbeat());
  }

  /// Empfangene Analyzer-Bilder seit dem letzten analyzer_start; der Host
  /// drosselt damit, wenn Bilder sich im WLAN stauen.
  int analyzerFramesReceived = 0;

  void _sendHeartbeat() => send('heartbeat', {'af': analyzerFramesReceived});

  void setForeground(bool value) {
    _foreground = value;
    _heartbeat?.cancel();
    if (value) {
      _startHeartbeat();
    } else {
      send('release');
    }
  }

  void send(String type, [Map<String, dynamic> payload = const {}]) {
    if (type == 'analyzer_start') analyzerFramesReceived = 0;
    final envelope = _envelope, socket = _socket;
    if (envelope == null || socket == null) return;
    try {
      socket.add(envelope.seal(type, payload));
    } catch (error) {
      _lost(error.toString());
    }
  }

  void sendMidi(Uint8List bytes) => send('midi', {'data': base64Encode(bytes)});

  void _lost(String why) {
    // Im Logcat sichtbar (auch Release), damit Abbrüche nachvollziehbar sind.
    debugPrint('Host-Verbindung verloren: $why');
    error = why;
    _disconnect(preservePresentation: true);
    if (!reconnecting) _clearPlayer();
  }

  void disconnect() {
    error = null;
    reconnecting = false;
    _disconnect();
  }

  void _disconnect({bool preservePresentation = false}) {
    final pending = _pendingConnection;
    _pendingConnection = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _generation++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _silenceWatch?.cancel();
    _silenceWatch = null;
    _envelope = null;
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    deviceName = null;
    if (!preservePresentation) _clearPlayer();
    _playerSubscribed = false;
    analyzerAvailable = false;
    analyzerVersion = 0;
    analyzerPlatform = null;
    notifyListeners();
  }

  void _clearPlayer() {
    playerAvailable = false;
    playerInfo = null;
    _playerStopTimer?.cancel();
    _playerStopTimer = null;
    _playerSubscribed = false;
    _playerOwners.clear();
  }

  @override
  void dispose() {
    disconnect();
    packets.close();
    analyzerEvents.close();
    super.dispose();
  }
}
