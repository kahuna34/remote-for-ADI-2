import 'dart:convert';

import 'package:adi2_remote/media/mpris.dart';
import 'package:adi2_remote/host/host_player_protocol.dart';
import 'package:adi2_remote/media/now_playing.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux PNG cover survives the bounded host player protocol', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH3sAAAAASUVORK5CYII=',
    );
    final decoded = decodeHostPlayerState(
      encodeHostPlayerState(NowPlayingInfo(title: 'Track', art: png)),
      null,
    );
    expect(decoded.art, png);
  });
  test(
    'MPRIS native metadata maps text, artists, microseconds and cover URI',
    () {
      for (final url in [
        'file:///tmp/cover.png',
        'http://example.com/cover.jpg',
        'https://example.com/cover.png',
      ]) {
        final state = parseMprisMetadata({
          'PlaybackStatus': 'Playing',
          'Position': 2500000,
          'Metadata': {
            'xesam:title': 'Track',
            'xesam:artist': ['Alice', 'Bob'],
            'xesam:album': 'Album',
            'mpris:length': 120000000,
            'mpris:artUrl': url,
          },
        }, app: 'VLC');
        expect(state.title, 'Track');
        expect(state.artist, 'Alice, Bob');
        expect(state.album, 'Album');
        expect(state.playing, isTrue);
        expect(state.position.inMilliseconds, 2500);
        expect(state.duration.inSeconds, 120);
        expect(state.artUrl.toString(), url);
        expect(state.app, 'VLC');
        final decoded = decodeHostPlayerState(
          encodeHostPlayerState(NowPlayingInfo.fromMpris(state)),
          null,
        );
        expect(decoded.album, 'Album');
        expect(decoded.position, state.position);
        expect(decoded.duration, state.duration);
      }
    },
  );

  test(
    'MPRIS unwraps D-Bus variants and handles missing or malformed metadata',
    () {
      final state = parseMprisMetadata({
        'PlaybackStatus': const DBusString('Paused'),
        'Metadata': DBusDict.stringVariant({
          'xesam:title': const DBusString('D-Bus track'),
          'xesam:artist': DBusArray.string(['Artist']),
          'mpris:length': const DBusInt64(1000000),
        }),
      });
      expect(state.title, 'D-Bus track');
      expect(state.artist, 'Artist');
      expect(state.playing, isFalse);
      expect(state.duration.inSeconds, 1);
      final empty = parseMprisMetadata({
        'Metadata': {
          'xesam:title': 3,
          'xesam:artist': false,
          'mpris:artUrl': 'javascript:bad',
          'mpris:length': -4,
        },
        'Position': 'bad',
      });
      expect(empty.title, isNull);
      expect(empty.artist, isNull);
      expect(empty.artUrl, isNull);
      expect(empty.position, Duration.zero);
      expect(empty.duration, Duration.zero);
    },
  );
}
