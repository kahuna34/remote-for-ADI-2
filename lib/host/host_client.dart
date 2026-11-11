import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'host_protocol.dart';

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

Future<WebSocket> _connectHostSocket(Uri uri) =>
    WebSocket.connect(uri.toString());

/// Abriss verwirft die gesamte Sitzung. Die nächste Verbindung verlangt
/// einen neuen Challenge-Response und einen neuen Geräteabgleich im Controller.
class HostClient extends ChangeNotifier {
  HostClient({HostSocketConnector? connectSocket})
    : _connectSocket = connectSocket ?? _connectHostSocket;
  final HostSocketConnector _connectSocket;
  final packets = StreamController<Uint8List>.broadcast(sync: true);
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
    disconnect();
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
          try {
            final message = decodeHostMessage(frame);
            if (_envelope != null) {
              final data = _envelope!.open(message);
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
              _envelope = HostEnvelope(
                key!,
                outgoing: 'client',
                incoming: 'server',
              );
              _startHeartbeat();
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
          _lost('Host getrennt');
        },
        onError: (Object e) {
          if (generation != _generation) return;
          if (!ready.isCompleted) ready.completeError(e);
          _lost(e.toString());
        },
      );
      await ready.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      if (generation == _generation) disconnect();
      rethrow;
    } finally {
      if (identical(_pendingConnection, ready)) _pendingConnection = null;
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    if (!_foreground || !connected) return;
    send('heartbeat');
    _heartbeat = Timer.periodic(
      hostHeartbeatInterval,
      (_) => send('heartbeat'),
    );
  }

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
    disconnect();
    error = why;
    notifyListeners();
  }

  void disconnect() {
    final pending = _pendingConnection;
    _pendingConnection = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _generation++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _envelope = null;
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    deviceName = null;
  }

  @override
  void dispose() {
    disconnect();
    packets.close();
    super.dispose();
  }
}
