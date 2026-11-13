import 'dart:convert';
import 'dart:typed_data';

import 'package:adi2_remote/host/host_player_protocol.dart';
import 'package:adi2_remote/host/host_protocol.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capability negotiation handles old and future hosts', () {
    for (final old in [null, 0, -1, '1', true]) {
      expect(negotiateHostPlayerVersion(old), 0);
    }
    expect(negotiateHostPlayerVersion(1), 1);
    expect(negotiateHostPlayerVersion(8), 1);
  });
  test('all player types are encrypted, authenticated and reject replays', () {
    for (final type in [
      'player_subscribe',
      'player_unsubscribe',
      'player_command',
      'player_state',
    ]) {
      final key = randomToken();
      final sender = HostEnvelope(key, outgoing: 'server', incoming: 'client');
      final receiver = HostEnvelope(
        key,
        outgoing: 'client',
        incoming: 'server',
      );
      final wire = sender.seal(type, {'title': 'Private track'});
      expect(wire, isNot(contains('Private track')));
      final frame = decodeHostMessage(wire);
      expect(
        () => receiver.open({...frame, 'type': 'midi'}),
        throwsFormatException,
      );
      expect(receiver.open(frame)['title'], 'Private track');
      expect(() => receiver.open(frame), throwsFormatException);
    }
  });
  test(
    '30 kB artwork fits encrypted frame; absent preserves and null clears',
    () {
      final art = Uint8List(30000)..setAll(0, [255, 216, 255]);
      final state = encodeHostPlayerState(
        NowPlayingInfo(
          title: '界' * 1024,
          artist: '界' * 1024,
          app: '界' * 1024,
          art: art,
        ),
      );
      final key = randomToken();
      final wire = HostEnvelope(
        key,
        outgoing: 'server',
        incoming: 'client',
      ).seal('player_state', state);
      expect(wire.length, lessThan(hostMaxPlayerFrameLength));
      final data = HostEnvelope(
        key,
        outgoing: 'client',
        incoming: 'server',
      ).open(decodeHostMessage(wire));
      final first = decodeHostPlayerState(data, null);
      expect(first.art, art);
      final second = decodeHostPlayerState({
        'title': 'New track',
        'playing': true,
      }, first);
      expect(identical(second.art, first.art), isTrue);
      expect(
        decodeHostPlayerState({'playing': false, 'artwork': null}, second).art,
        isNull,
      );
      expect(
        () => decodeHostPlayerState({
          'playing': false,
          'artwork': base64Encode(Uint8List(30001)),
        }, null),
        throwsFormatException,
      );
      expect(
        () => decodeHostPlayerState({
          'playing': false,
          'artwork': base64Encode([1, 2, 3]),
        }, null),
        throwsFormatException,
      );
      expect(
        () => decodeHostMessage(wire.replaceFirst('player_state', 'midi')),
        throwsFormatException,
      );
    },
  );
}
