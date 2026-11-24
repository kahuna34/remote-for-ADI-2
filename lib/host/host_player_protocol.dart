import 'dart:convert';
import 'dart:typed_data';

import '../media/now_playing.dart';

const hostPlayerVersion = 1;
const hostPlayerArtworkLimit = 30000;

/// Großes Cover nur für die eigene Oberfläche über 127.0.0.1.
const hostPlayerLargeArtworkLimit = 600000;
const hostPlayerCommands = {'play', 'pause', 'toggle', 'next', 'previous'};

int negotiateHostPlayerVersion(Object? version) =>
    version is int && version >= hostPlayerVersion ? hostPlayerVersion : 0;

/// An omitted artwork field preserves the previous cover; null clears it.
NowPlayingInfo decodeHostPlayerState(
  Map<String, dynamic> data,
  NowPlayingInfo? previous,
) {
  String? text(String key) {
    final value = data[key];
    if (value != null && (value is! String || value.length > 1024)) {
      throw const FormatException('Invalid player text');
    }
    return value as String?;
  }

  Uint8List? art = previous?.art;
  if (data.containsKey('artwork')) {
    final encoded = data['artwork'];
    art = null;
    if (encoded != null) {
      if (encoded is! String ||
          encoded.length > (hostPlayerLargeArtworkLimit * 4 ~/ 3) + 4) {
        throw const FormatException('Invalid artwork');
      }
      art = base64Decode(encoded);
      final png =
          art.length >= 8 &&
          art[0] == 0x89 &&
          art[1] == 0x50 &&
          art[2] == 0x4e &&
          art[3] == 0x47 &&
          art[4] == 13 &&
          art[5] == 10 &&
          art[6] == 26 &&
          art[7] == 10;
      final jpeg =
          art.length >= 3 && art[0] == 0xff && art[1] == 0xd8 && art[2] == 0xff;
      if (art.length > hostPlayerLargeArtworkLimit || (!jpeg && !png)) {
        throw const FormatException('Invalid JPEG/PNG');
      }
    }
  }
  if (data['playing'] is! bool) {
    throw const FormatException('Invalid playback state');
  }
  return NowPlayingInfo(
    title: text('title'),
    artist: text('artist'),
    app: text('app'),
    playing: data['playing'] == true,
    art: art,
    album: text('album'),
    position: data['positionUs'] is int && data['positionUs'] >= 0
        ? Duration(microseconds: data['positionUs'] as int)
        : null,
    duration: data['durationUs'] is int && data['durationUs'] >= 0
        ? Duration(microseconds: data['durationUs'] as int)
        : null,
  );
}

Map<String, dynamic> encodeHostPlayerState(
  NowPlayingInfo info, {
  bool large = false,
}) => {
  'title': (info.title ?? '').substring(
    0,
    (info.title ?? '').length.clamp(0, 1024),
  ),
  'artist': (info.artist ?? '').substring(
    0,
    (info.artist ?? '').length.clamp(0, 1024),
  ),
  'app': (info.app ?? '').substring(0, (info.app ?? '').length.clamp(0, 1024)),
  'playing': info.playing,
  if (info.album != null)
    'album': info.album!.substring(0, info.album!.length.clamp(0, 1024)),
  if (info.position != null) 'positionUs': info.position!.inMicroseconds,
  if (info.duration != null) 'durationUs': info.duration!.inMicroseconds,
  'artwork':
      large &&
          info.artLarge != null &&
          info.artLarge!.length <= hostPlayerLargeArtworkLimit
      ? base64Encode(info.artLarge!)
      : info.art != null && info.art!.length <= hostPlayerArtworkLimit
      ? base64Encode(info.art!)
      : null,
};
