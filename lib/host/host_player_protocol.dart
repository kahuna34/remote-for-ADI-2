import 'dart:convert';
import 'dart:typed_data';

import '../media/now_playing.dart';

const hostPlayerVersion = 1;
const hostPlayerArtworkLimit = 30000;
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
      if (encoded is! String || encoded.length > 40000) {
        throw const FormatException('Invalid artwork');
      }
      art = base64Decode(encoded);
      if (art.length > hostPlayerArtworkLimit ||
          art.length < 3 ||
          art[0] != 0xff ||
          art[1] != 0xd8 ||
          art[2] != 0xff) {
        throw const FormatException('Invalid JPEG');
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
  );
}

Map<String, dynamic> encodeHostPlayerState(NowPlayingInfo info) => {
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
  'artwork': info.art != null && info.art!.length <= hostPlayerArtworkLimit
      ? base64Encode(info.art!)
      : null,
};
