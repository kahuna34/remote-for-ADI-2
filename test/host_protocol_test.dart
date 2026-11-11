import 'dart:convert';

import 'package:adi2_remote/host/host_pairing.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/protocol/adi2_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Umschlag, MIDI und richtungsgebundener HMAC', () {
    final key = randomToken();
    final client = HostEnvelope(key, outgoing: 'client', incoming: 'server');
    final server = HostEnvelope(key, outgoing: 'server', incoming: 'client');
    final midi = buildRequestAll(0x71);
    final frame = client.seal('midi', {'data': base64Encode(midi)});
    final result = server.open(decodeHostMessage(frame));
    expect(result['type'], 'midi');
    expect(decodeMidi(result['data']), midi);
    expect(() => server.open(decodeHostMessage(frame)), throwsFormatException);
    expect(
      () => client.open(decodeHostMessage(client.seal('heartbeat'))),
      throwsFormatException,
    );
  });

  test('Falscher HMAC, Manipulation und Reihenfolge verworfen', () {
    final key = randomToken();
    final client = HostEnvelope(key, outgoing: 'client', incoming: 'server');
    final server = HostEnvelope(key, outgoing: 'server', incoming: 'client');
    final first = decodeHostMessage(client.seal('heartbeat'));
    final second = decodeHostMessage(client.seal('heartbeat'));
    expect(() => server.open(second), throwsFormatException);
    expect(
      () => server.open({...first, 'type': 'midi'}),
      throwsFormatException,
    );
    expect(
      () => server.open({...first, 'mac': randomToken()}),
      throwsFormatException,
    );
    expect(server.open(first)['type'], 'heartbeat');
    expect(server.open(second)['type'], 'heartbeat');
    expect(() => decodeHostMessage('[]'), throwsFormatException);
    expect(() => decodeMidi(base64Encode([0xf0, 0xf7])), throwsFormatException);
  });

  test('Challenge, Smartphone, Host und Nonce binden Sitzungsschlüssel', () {
    final key = randomToken();
    final context = authContext('host', 'phone', 'challenge', 'nonce');
    final proof = hostMac(key, ['client', ...context]);
    expect(secureEquals(proof, hostMac(key, ['client', ...context])), isTrue);
    expect(proof, isNot(hostMac(key, ['server', ...context])));
    expect(
      sessionKey(key, context),
      isNot(sessionKey(key, [...context, 'other'])),
    );
    expect(base64Url.decode(key), hasLength(32));
  });

  test('Kopplung gültig, einmalig, abgelaufen und widerrufbar', () {
    var now = DateTime(2026);
    final pairing = HostPairing(now: () => now);
    final code = pairing.issue();
    expect(code, matches(RegExp(r'^\d{6}$')));
    expect(pairing.redeem('wrong', 'phone', 'Handy'), isNull);
    final paired = pairing.redeem(code, 'phone', 'Handy');
    expect(paired, isNotNull);
    expect(pairing.redeem(code, 'other', 'Handy'), isNull);
    pairing.revoke('phone');
    expect(pairing.devices, isEmpty);
    final expired = pairing.issue();
    now = now.add(hostPairingLifetime);
    expect(pairing.redeem(expired, 'phone', 'Handy'), isNull);
  });

  test('Code wird nach fünf Fehlversuchen gesperrt', () {
    final pairing = HostPairing();
    final code = pairing.issue();
    for (var i = 0; i < 5; i++) {
      pairing.redeem('wrong', 'phone', 'Name');
    }
    expect(pairing.redeem(code, 'phone', 'Name'), isNull);
  });
}
