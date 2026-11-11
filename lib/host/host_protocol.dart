// Gemeinsames LAN-Protokoll. Stufe 1 authentifiziert, aber unverschlüsselt.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const hostServiceType = '_adi2remote._tcp';
const hostDefaultPort = 47321;
const hostHeartbeatInterval = Duration(milliseconds: 300);
const hostGrantLifetime = Duration(seconds: 1);
const hostPairingLifetime = Duration(minutes: 2);

String randomToken([int bytes = 32]) => base64UrlEncode(
  List<int>.generate(bytes, (_) => Random.secure().nextInt(256)),
);

String hostMac(String key, Object data) => base64UrlEncode(
  Hmac(
    sha256,
    base64Url.decode(key),
  ).convert(utf8.encode(jsonEncode(data))).bytes,
);

bool secureEquals(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ (i < b.length ? b.codeUnitAt(i) : 0);
  }
  return difference == 0;
}

List<String> authContext(
  String hostId,
  String deviceId,
  String challenge,
  String nonce,
) => ['adi2-host-v1', hostId, deviceId, challenge, nonce];

String sessionKey(String key, List<String> context) =>
    hostMac(key, ['session', ...context]);

Map<String, dynamic> decodeHostMessage(dynamic frame) {
  if (frame is! String || frame.length > 32768) {
    throw const FormatException('Ungueltiger Nachrichtenrahmen');
  }
  final value = jsonDecode(frame);
  if (value is! Map<String, dynamic> || value['type'] is! String) {
    throw const FormatException('Ungueltiger Umschlag');
  }
  return value;
}

Uint8List decodeMidi(Object? encoded) {
  if (encoded is! String) throw const FormatException('MIDI fehlt');
  final data = base64Decode(encoded);
  if (data.length < 7 ||
      data.length > 4096 ||
      data.first != 0xf0 ||
      data.last != 0xf7 ||
      data.sublist(1, data.length - 1).any((b) => b > 127)) {
    throw const FormatException('Vollstaendige SysEx erwartet');
  }
  return data;
}

/// Strikt fortlaufend, richtungsgebunden, ohne Sende- oder Wiederholpuffer.
class HostEnvelope {
  HostEnvelope(this.key, {required this.outgoing, required this.incoming});
  final String key, outgoing, incoming;
  int _sent = 0, _received = 0;

  String seal(String type, [Map<String, dynamic> payload = const {}]) {
    final sequence = ++_sent;
    final body = jsonEncode(payload);
    return jsonEncode({
      'type': type,
      'seq': sequence,
      'body': body,
      'mac': hostMac(key, [outgoing, sequence, type, body]),
    });
  }

  Map<String, dynamic> open(Map<String, dynamic> message) {
    final type = message['type'];
    final seq = message['seq'];
    final body = message['body'];
    final mac = message['mac'];
    if (seq is! int ||
        seq != _received + 1 ||
        body is! String ||
        mac is! String ||
        !secureEquals(mac, hostMac(key, [incoming, seq, type, body]))) {
      throw const FormatException('Sequenz oder HMAC ungueltig');
    }
    final payload = jsonDecode(body);
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Ungueltige Nutzdaten');
    }
    _received = seq;
    return {...payload, 'type': type};
  }
}

class HostEndpoint {
  const HostEndpoint({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
  });
  final String id, name, address;
  final int port;
  Uri get uri => Uri(scheme: 'ws', host: address, port: port, path: '/adi2');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'port': port,
  };
  factory HostEndpoint.fromJson(Map<String, dynamic> j) => HostEndpoint(
    id: j['id'] as String,
    name: j['name'] as String,
    address: j['address'] as String,
    port: j['port'] as int,
  );
}
